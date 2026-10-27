import CoreVideo
import Foundation

/// Basically the analyzer in reverse: we know the frequency and solve for readout time.
public struct RealDeviceCalibrator: DeviceCalibrating {
    public init() {}

    public func solveLineReadoutTime(
        from frames: FrameSequence,
        knownFrequencyHz: Double
    ) async throws -> TimeInterval {
        try Task.checkCancellation()
        guard knownFrequencyHz > 0, knownFrequencyHz.isFinite else {
            throw AnalysisError.insufficientSignal(reason: "non-positive reference frequency")
        }

        // Same signature `MeasurementRunner` validates against, so both agree on what's plausible.
        let format = frames.metadata.conditions?.formatSignature ?? CaptureFormatSignature(metadata: frames.metadata)
        let plausible = DeviceCalibration.plausibleLineReadoutRange(for: format)

        let solution = try ReadoutSolver.solve(
            frames: frames,
            frequencyHz: knownFrequencyHz,
            plausible: plausible
        )

        guard plausible.contains(solution.lineReadoutTime) else {
            throw AnalysisError.implausibleCalibration(solved: solution.lineReadoutTime, plausible: plausible)
        }
        return solution.lineReadoutTime
    }

    /// Fits the camera response from the ISO sweep; see `ResponseCurveSolver`.
    public func solveResponseCurve(from sweep: [FrameSequence]) async throws -> ResponseCurve {
        try Task.checkCancellation()
        return try ResponseCurveSolver.solve(sweep: sweep).curve
    }
}

// MARK: - Readout solver

/// What the readout search found, kept for tests and diagnostics.
struct ReadoutSolution: Sendable {
    let lineReadoutTime: TimeInterval

    /// Peak power over the noise expected at that readout time, from this capture's own residuals.
    /// About 1 means no flicker at all.
    let significance: Double

    /// Threshold `significance` had to clear; pure noise passes once in `1 / falseAlarmProbability` captures.
    let significanceThreshold: Double

    /// The `k` of the sub-multiple the harmonic guard moved to, if it fired.
    let harmonicGuardDivisor: Int?
    let usableRowFraction: Double
}

/// Searches line readout time `L` directly by fitting one waveform across all frames using their real timestamps.
/// Fitting coherently across frames avoids needing a full cycle per frame and can't lock onto a harmonic.
enum ReadoutSolver {

    /// The fundamental plus the harmonics a magnetic ballast adds.
    static let harmonicCount = 3

    /// Rows get averaged into this many blocks; the pattern tops out around 13 cycles per frame, so nothing's lost.
    static let targetBlockCount = 128

    /// Columns sampled per row; a defocused scene doesn't need more.
    static let maximumSampledColumns = 256

    static let minimumFrameCount = 8

    /// Searching past the plausible ceiling means an out-of-range readout gets refused instead of clipped and accepted.
    static let searchCeilingFactor = 2.0

    /// Grid steps per main-lobe width of the highest harmonic.
    static let gridOversampling = 6.0

    /// A row is unusable if its mean is within this many codes of black.
    static let minimumRowSignalCodes: Float = 4

    /// Chance a capture with no flicker at all passes the significance test.
    static let falseAlarmProbability = 1e-3

    /// Also measure noise this close (Hz) to each harmonic's alias, so hand tremor there isn't averaged away.
    static let localNoiseOffsetsHz: [Double] = [-3, -2.5, -2, -1.5, 1.5, 2, 2.5, 3]

    /// Offsets closer than this to a fitted term would understate the noise, since the fit already zeroed them.
    static let localNoiseClearanceHz = 1.0

    static func solve(
        frames: FrameSequence,
        frequencyHz: Double,
        plausible: ClosedRange<TimeInterval>
    ) throws -> ReadoutSolution {
        guard frames.count >= minimumFrameCount else {
            throw AnalysisError.tooFewFrames(captured: frames.count, required: minimumFrameCount)
        }
        // This all depends on the light's phase drifting between frames. If the camera runs in step with it,
        // every frame looks the same and the flat field wipes it out, so say that clearly instead of "no signal".
        let frameRate = estimatedFrameRate(frames.metadata)
        let drift = phaseDriftCycles(frequencyHz: frequencyHz, frameRate: frameRate, frameCount: frames.count)
        guard drift >= minimumPhaseDriftCycles else {
            throw AnalysisError.frameRateLockedToLight(frameRate: frameRate, lightHz: frequencyHz)
        }

        let data = try RatioBlocks(frames: frames)
        try Task.checkCancellation()

        let search = Search(data: data, frequencyHz: frequencyHz, frameRate: frameRate)

        // Stage 1: coherent power on a uniform grid, since every lobe in L has the same width.
        let lower = plausible.lowerBound * 0.5
        let upper = max(plausible.upperBound * searchCeilingFactor, lower * 4)
        let lobe = search.lobeWidth(harmonic: 1)
        let step = search.lobeWidth(harmonic: harmonicCount) / gridOversampling
        let gridCount = min(4000, max(16, Int(((upper - lower) / step).rounded(.up)) + 1))
        let gridStep = (upper - lower) / Double(gridCount - 1)

        var grid: [(L: Double, power: Double)] = []
        grid.reserveCapacity(gridCount)
        for index in 0..<gridCount {
            if index % 64 == 0 { try Task.checkCancellation() }
            let L = lower + Double(index) * gridStep
            grid.append((L, search.evaluate(L)))
        }

        guard let bestIndex = grid.indices.max(by: { grid[$0].power < grid[$1].power }),
              grid[bestIndex].power > 0 else {
            throw AnalysisError.referenceFlickerNotFound(reason: "reference capture had no structure at the known frequency")
        }

        // Negative L means the sensor reads the last row first. The analyzer assumes row 0 first,
        // so a stronger mirrored peak gets refused rather than risk matching a wrong positive L.
        var reversed = (L: -lower, power: 0.0)
        for index in 0..<gridCount {
            if index % 64 == 0 { try Task.checkCancellation() }
            let L = -(lower + Double(index) * gridStep)
            let power = search.evaluate(L)
            if power > reversed.power { reversed = (L, power) }
        }

        // Stage 2: coherent refine between the neighbouring grid points.
        var best = search.refine(around: grid[bestIndex].L, halfWidth: gridStep, floor: lower)

        // Judge significance against this capture's own noise at the solved L, not against other candidates.
        // Searching both directions doubles the trial count the threshold accounts for.
        let trials = 2 * max(1, (upper - lower) / search.lobeWidth(harmonic: harmonicCount))
        let threshold = significanceThreshold(trials: trials, harmonics: harmonicCount)
        let significance = best.power / search.noisePower(at: best.L)

        // The mirrored peak has to pass the same test, or a steady light would read as a reversed sensor.
        if reversed.power > best.power, reversed.power / search.noisePower(at: reversed.L) >= threshold {
            throw AnalysisError.readoutDirectionReversed
        }

        guard significance >= threshold else {
            throw AnalysisError.referenceFlickerNotFound(
                reason: "flicker at \(Int(frequencyHz.rounded())) Hz was "
                    + String(format: "%.1f× the measured noise floor; needs %.1f×", significance, threshold)
            )
        }

        // Harmonic guard: if L*/k has comparable power, L* may be a harmonic lock-on, so take the smallest one.
        // Only test sub-multiples far enough from L* to resolve, or the peak's own lobe would trip it.
        var guardDivisor: Int?
        let peakPower = best.power
        for k in (2...4).reversed() {
            let candidate = best.L / Double(k)
            guard candidate >= plausible.lowerBound, best.L - candidate >= 1.5 * lobe else { continue }
            let refined = search.refine(around: candidate, halfWidth: gridStep, floor: lower)
            if refined.power >= CaptureStandard.readoutHarmonicGuardRatio * peakPower {
                best = refined
                guardDivisor = k
                break
            }
        }

        return ReadoutSolution(
            lineReadoutTime: best.L,
            significance: significance,
            significanceThreshold: threshold,
            harmonicGuardDivisor: guardDivisor,
            usableRowFraction: data.usableRowFraction
        )
    }

    /// Below two cycles of drift, the cross-frame fit can't separate flicker from the scene and slow drift.
    static let minimumPhaseDriftCycles = 2.0

    /// Significance threshold for noise alone, from a Gamma(K, 1/K) distribution,
    /// set so pure noise passes at `falseAlarmProbability` given the number of trials.
    static func significanceThreshold(trials: Double, harmonics: Int) -> Double {
        let target = falseAlarmProbability / max(1, trials)
        func survival(_ y: Double) -> Double {
            var term = 1.0
            var sum = 1.0
            for i in 1..<max(1, harmonics) {
                term *= y / Double(i)
                sum += term
            }
            return exp(-y) * sum
        }
        var low = 0.0
        var high = 200.0
        for _ in 0..<100 {
            let mid = (low + high) / 2
            if survival(mid) > target { low = mid } else { high = mid }
        }
        return high / Double(max(1, harmonics))
    }

    /// How many cycles the light's phase drifts across the capture, relative to the frames.
    static func phaseDriftCycles(frequencyHz: Double, frameRate: Double, frameCount: Int) -> Double {
        guard frameRate > 0, frequencyHz > 0 else { return 0 }
        let cyclesPerFrame = frequencyHz / frameRate
        let offset = abs(cyclesPerFrame - cyclesPerFrame.rounded())
        return offset * Double(frameCount)
    }

    /// 1 / median frame delta, or the nominal rate if timestamps are unusable.
    static func estimatedFrameRate(_ metadata: CaptureMetadata) -> Double {
        let frames = metadata.frames
        guard frames.count >= 2 else { return metadata.nominalFrameRate }
        var deltas: [Double] = []
        for index in 1..<frames.count {
            let delta = frames[index].presentationTime - frames[index - 1].presentationTime
            if delta > 0 { deltas.append(delta) }
        }
        guard !deltas.isEmpty else { return metadata.nominalFrameRate }
        return 1 / deltas.sorted()[deltas.count / 2]
    }

    // MARK: Coherent search

    /// Each row block's complex amplitude at every harmonic, fitted across all frames.
    /// The phase slope across blocks depends only on L, so searching L means fitting that slope.
    struct Search {
        let frequencyHz: Double
        private let rows: [Double]
        private let weights: [Double]
        private let rowSpan: Double
        /// [harmonic][block]
        private let signal: [[Complex]]
        /// Whatever the fit didn't explain: noise, hand sway, anything that isn't the light.
        private let residuals: [Double]
        private let times: [Double]
        private let frameCount: Int
        /// Per harmonic, how much residual noise on each frame leaks into its amplitude.
        private let coefficientVariance: [Double]
        private let degreesOfFreedom: Double
        /// Per harmonic, the offsets (Hz) where local noise gets measured.
        private let localOffsets: [[Double]]

        init(data: RatioBlocks, frequencyHz: Double, frameRate: Double) {
            self.frequencyHz = frequencyHz
            rows = data.rows
            weights = data.weights
            rowSpan = data.rowSpan
            times = data.times
            frameCount = data.frameCount

            let signalFrequencies = (1...harmonicCount).map { Double($0) * frequencyHz }
            let fit = Search.fitSinusoids(data: data, frequencies: signalFrequencies)
            signal = fit.amplitudes
            residuals = fit.residuals
            coefficientVariance = fit.coefficientVariance
            degreesOfFreedom = Double(max(1, data.frameCount - fit.parameterCount))
            localOffsets = signalFrequencies.map { hz in
                Search.localNoiseOffsets(around: hz, fitted: signalFrequencies, frameRate: frameRate)
            }
        }

        struct Fit {
            /// [frequency][block], a_m − i·b_m.
            var amplitudes: [[Complex]]
            var residuals: [Double]
            var coefficientVariance: [Double]
            var parameterCount: Int
        }

        /// Trend columns that fit out slow drift (hand sway, a lamp warming up) so it doesn't inflate the noise.
        static let trendTerms = 2

        /// Per block, a joint least-squares fit of a slow trend plus every harmonic over frames.
        /// Fitting jointly avoids leakage between harmonics that would bend the phase slope by several percent.
        static func fitSinusoids(data: RatioBlocks, frequencies: [Double]) -> Fit {
            let base = 1 + trendTerms
            let p = base + 2 * frequencies.count
            let n = data.frameCount
            let zero = Fit(
                amplitudes: frequencies.map { _ in [Complex](repeating: Complex(0, 0), count: data.blockCount) },
                residuals: data.ratios,
                coefficientVariance: frequencies.map { _ in .infinity },
                parameterCount: p
            )
            guard n > p else { return zero }
            let first = data.times.first ?? 0
            let last = data.times.last ?? 0
            let middle = (first + last) / 2
            let halfSpan = max((last - first) / 2, 1e-9)
            var design = [Double](repeating: 0, count: n * p)
            for f in 0..<n {
                let tau = (data.times[f] - middle) / halfSpan
                design[f * p] = 1
                design[f * p + 1] = tau
                design[f * p + 2] = tau * tau
                for (m, hz) in frequencies.enumerated() {
                    let phase = 2 * Double.pi * hz * data.times[f]
                    design[f * p + base + 2 * m] = cos(phase)
                    design[f * p + base + 1 + 2 * m] = sin(phase)
                }
            }
            var gram = [Double](repeating: 0, count: p * p)
            for f in 0..<n {
                for i in 0..<p {
                    for k in 0..<p { gram[i * p + k] += design[f * p + i] * design[f * p + k] }
                }
            }
            // A tiny bit of ridge keeps the fit solvable when phases don't drift; it'll just be weak, not wrong.
            for i in 0..<p { gram[i * p + i] += 1e-9 * Double(n) }
            guard let inverse = invert(gram, size: p) else { return zero }
            // hat = G⁻¹ Xᵀ, p × n.
            var hat = [Double](repeating: 0, count: p * n)
            for i in 0..<p {
                for f in 0..<n {
                    var value = 0.0
                    for k in 0..<p { value += inverse[i * p + k] * design[f * p + k] }
                    hat[i * n + f] = value
                }
            }
            var amplitudes = zero.amplitudes
            var residuals = data.ratios
            var coefficients = [Double](repeating: 0, count: p)
            data.ratios.withUnsafeBufferPointer { ratios in
                for j in 0..<data.blockCount {
                    for i in 0..<p {
                        var value = 0.0
                        for f in 0..<n { value += hat[i * n + f] * ratios[f * data.blockCount + j] }
                        coefficients[i] = value
                    }
                    for m in frequencies.indices {
                        amplitudes[m][j] = Complex(coefficients[base + 2 * m], -coefficients[base + 1 + 2 * m])
                    }
                    for f in 0..<n {
                        var model = 0.0
                        for i in 0..<p { model += design[f * p + i] * coefficients[i] }
                        residuals[f * data.blockCount + j] -= model
                    }
                }
            }
            let variance = frequencies.indices.map { m -> Double in
                let a = base + 2 * m
                return inverse[a * p + a] + inverse[(a + 1) * p + (a + 1)]
            }
            return Fit(amplitudes: amplitudes, residuals: residuals, coefficientVariance: variance, parameterCount: p)
        }

        /// Gauss–Jordan with partial pivoting; nil if singular.
        static func invert(_ matrix: [Double], size n: Int) -> [Double]? {
            var a = matrix
            var inverse = [Double](repeating: 0, count: n * n)
            for i in 0..<n { inverse[i * n + i] = 1 }
            for column in 0..<n {
                var pivot = column
                for row in column..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
                guard abs(a[pivot * n + column]) > 1e-300 else { return nil }
                if pivot != column {
                    for k in 0..<n {
                        a.swapAt(pivot * n + k, column * n + k)
                        inverse.swapAt(pivot * n + k, column * n + k)
                    }
                }
                let scale = 1 / a[column * n + column]
                for k in 0..<n {
                    a[column * n + k] *= scale
                    inverse[column * n + k] *= scale
                }
                for row in 0..<n where row != column {
                    let factor = a[row * n + column]
                    guard factor != 0 else { continue }
                    for k in 0..<n {
                        a[row * n + k] -= factor * a[column * n + k]
                        inverse[row * n + k] -= factor * inverse[column * n + k]
                    }
                }
            }
            return inverse
        }

        /// Width in L of harmonic k's main lobe: one extra cycle across the usable rows.
        func lobeWidth(harmonic k: Int) -> Double {
            1 / (Double(k) * frequencyHz * max(rowSpan, 1))
        }

        /// Total power with all blocks' phases lined up for this L. Negative L means the last row is read first.
        func evaluate(_ L: Double) -> Double {
            var power = 0.0
            for k in 0..<harmonicCount {
                let omega = 2 * Double.pi * Double(k + 1) * frequencyHz * L
                var sum = Complex(0, 0)
                for j in rows.indices {
                    let phase = omega * rows[j]
                    sum = sum + signal[k][j] * Complex(weights[j] * cos(phase), -weights[j] * sin(phase))
                }
                power += sum.magnitudeSquared
            }
            return power
        }

        /// Power `evaluate(L)` would show from noise alone, combining residuals across blocks the same way as the signal.
        /// Per harmonic, takes the larger of average and near-alias noise so concentrated tremor still counts.
        func noisePower(at L: Double) -> Double {
            let blockCount = rows.count
            var total = 0.0
            for k in 0..<harmonicCount {
                guard coefficientVariance[k].isFinite else { return .infinity }
                let omega = 2 * Double.pi * Double(k + 1) * frequencyHz * L
                var rotation = [Complex](repeating: Complex(0, 0), count: blockCount)
                for j in 0..<blockCount {
                    let phase = omega * rows[j]
                    rotation[j] = Complex(weights[j] * cos(phase), -weights[j] * sin(phase))
                }
                // This frame's residual, combined across blocks the same way as the signal.
                var combined = [Complex](repeating: Complex(0, 0), count: frameCount)
                var whitePower = 0.0
                for f in 0..<frameCount {
                    var z = Complex(0, 0)
                    for j in 0..<blockCount {
                        let r = residuals[f * blockCount + j]
                        z = z + Complex(rotation[j].re * r, rotation[j].im * r)
                    }
                    combined[f] = z
                    whitePower += z.magnitudeSquared
                }
                let white = whitePower / degreesOfFreedom
                // Local estimate of the same per-frame power, but at frequencies right next to this harmonic.
                var local: [Double] = []
                for offset in localOffsets[k] {
                    let hz = Double(k + 1) * frequencyHz + offset
                    var sum = Complex(0, 0)
                    for f in 0..<frameCount {
                        let phase = -2 * Double.pi * hz * times[f]
                        sum = sum + combined[f] * Complex(cos(phase), sin(phase))
                    }
                    local.append(sum.magnitudeSquared / Double(frameCount))
                }
                let localMedian = local.isEmpty ? 0 : local.sorted()[local.count / 2]
                let perFrame = max(white, localMedian * Double(frameCount) / degreesOfFreedom)
                total += coefficientVariance[k] * perFrame
            }
            return total
        }

        /// Golden-section search for the max within ±`halfWidth`; the peak is smooth at this scale.
        func refine(around center: Double, halfWidth: Double, floor: Double) -> (L: Double, power: Double) {
            var a = max(floor, center - halfWidth)
            var b = center + halfWidth
            let ratio = (sqrt(5.0) - 1) / 2
            var c = b - ratio * (b - a)
            var d = a + ratio * (b - a)
            var fc = evaluate(c)
            var fd = evaluate(d)
            for _ in 0..<60 where (b - a) > center * 1e-7 {
                if fc > fd {
                    b = d; d = c; fd = fc
                    c = b - ratio * (b - a)
                    fc = evaluate(c)
                } else {
                    a = c; c = d; fc = fd
                    d = a + ratio * (b - a)
                    fd = evaluate(d)
                }
            }
            let centerPower = evaluate(center)
            let mid = (a + b) / 2
            let midPower = evaluate(mid)
            return midPower >= centerPower ? (mid, midPower) : (center, centerPower)
        }

        /// Offsets (Hz) from `hz` whose aliases stay clear of every fitted term, harmonics and slow drift included.
        static func localNoiseOffsets(around hz: Double, fitted: [Double], frameRate: Double) -> [Double] {
            guard frameRate > 0 else { return [] }
            func aliasDistance(_ value: Double) -> Double {
                let wrapped = value.truncatingRemainder(dividingBy: frameRate)
                let positive = wrapped < 0 ? wrapped + frameRate : wrapped
                return min(positive, frameRate - positive)
            }
            return localNoiseOffsetsHz.filter { offset in
                let candidate = hz + offset
                guard aliasDistance(candidate) >= localNoiseClearanceHz else { return false }
                return fitted.allSatisfy { reference in
                    aliasDistance(candidate - reference) >= localNoiseClearanceHz
                        && aliasDistance(candidate + reference) >= localNoiseClearanceHz
                }
            }
        }
    }

    // MARK: Data

    /// Flat-field-normalized, row-block-averaged samples.
    /// Dividing each row by its mean removes the scene, and phase drift keeps that mean flicker-free.
    struct RatioBlocks {
        let frameCount: Int
        let blockCount: Int
        /// Mean row index of each block's usable rows.
        let rows: [Double]
        /// Usable rows per block.
        let weights: [Double]
        /// r − 1 per block, frame-major. Not detrended, since demodulation already rejects hand shake
        /// and detrending would strip a pattern that spans under one cycle.
        let ratios: [Double]
        /// Seconds since the first frame.
        let times: [Double]
        let rowSpan: Double
        let usableRowFraction: Double

        init(frames: FrameSequence) throws {
            let levels = LumaCodeLevels(pixelFormat: frames.metadata.pixelFormat)
            let frameCount = frames.count
            var height = 0
            var rowMeans: [Float] = []
            var saturatedFraction: [Float] = []

            try frames.forEachPlane { index, plane, _ in
                if index == 0 {
                    height = plane.height
                    rowMeans = [Float](repeating: 0, count: frameCount * height)
                    saturatedFraction = [Float](repeating: 0, count: height)
                }
                if index % 16 == 0 { try Task.checkCancellation() }
                guard plane.height == height, plane.width > 0 else {
                    throw AnalysisError.pixelBufferUnreadable(frameIndex: index, code: -3)
                }
                let stride = max(1, plane.width / maximumSampledColumns)
                let sampled = (plane.width + stride - 1) / stride
                let saturation = UInt8(levels.saturation)
                for y in 0..<height {
                    let row = plane.baseAddress.advanced(by: y * plane.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    var sum = 0
                    var saturated = 0
                    var x = 0
                    while x < plane.width {
                        let value = row[x]
                        sum += Int(value)
                        if value >= saturation { saturated += 1 }
                        x += stride
                    }
                    rowMeans[index * height + y] = Float(sum) / Float(sampled)
                    let fraction = Float(saturated) / Float(sampled)
                    if fraction > saturatedFraction[y] { saturatedFraction[y] = fraction }
                }
            }
            guard height > 0 else { throw AnalysisError.tooFewFrames(captured: 0, required: minimumFrameCount) }

            // Flat field and row exclusion, same rules as spec C2.
            let black = Float(levels.black)
            var usable = [Bool](repeating: false, count: height)
            var flat = [Float](repeating: 0, count: height)
            var saturatedRows = 0
            for y in 0..<height {
                var sum: Float = 0
                for f in 0..<frameCount { sum += rowMeans[f * height + y] }
                let mean = sum / Float(frameCount) - black
                flat[y] = mean
                let saturated = Double(saturatedFraction[y]) > CaptureStandard.saturatedRowPixelFraction
                if saturated { saturatedRows += 1 }
                usable[y] = !saturated && mean >= minimumRowSignalCodes
            }
            let usableCount = usable.filter { $0 }.count
            let usableFraction = Double(usableCount) / Double(height)
            guard usableFraction >= CaptureStandard.minimumUsableRowFraction else {
                if saturatedRows > height / 2 { throw AnalysisError.sensorSaturated }
                throw AnalysisError.insufficientSignal(reason: "reference capture was too dark to calibrate from")
            }

            let blockSize = max(1, height / targetBlockCount)
            var rows: [Double] = []
            var weights: [Double] = []
            var members: [[Int]] = []
            var start = 0
            while start < height {
                let end = min(height, start + blockSize)
                let inBlock = (start..<end).filter { usable[$0] }
                if !inBlock.isEmpty {
                    rows.append(Double(inBlock.reduce(0, +)) / Double(inBlock.count))
                    weights.append(Double(inBlock.count))
                    members.append(inBlock)
                }
                start = end
            }
            let blockCount = rows.count
            guard blockCount >= 8 else {
                throw AnalysisError.insufficientSignal(reason: "too few usable rows to calibrate from")
            }

            var ratios = [Double](repeating: 0, count: frameCount * blockCount)
            for f in 0..<frameCount {
                for j in 0..<blockCount {
                    var sum: Float = 0
                    for y in members[j] {
                        sum += (rowMeans[f * height + y] - black) / flat[y] - 1
                    }
                    ratios[f * blockCount + j] = Double(sum) / weights[j]
                }
            }

            let start0 = frames.metadata.frames.first?.presentationTime ?? 0
            self.frameCount = frameCount
            self.blockCount = blockCount
            self.rows = rows
            self.weights = weights
            self.ratios = ratios
            self.times = frames.metadata.frames.map { $0.presentationTime - start0 }
            self.rowSpan = (rows.last ?? 0) - (rows.first ?? 0)
            self.usableRowFraction = usableFraction
        }
    }

    struct Complex {
        var re: Double
        var im: Double
        init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
        var magnitudeSquared: Double { re * re + im * im }
        static func + (lhs: Complex, rhs: Complex) -> Complex { Complex(lhs.re + rhs.re, lhs.im + rhs.im) }
        static func * (lhs: Complex, rhs: Complex) -> Complex {
            Complex(lhs.re * rhs.re - lhs.im * rhs.im, lhs.re * rhs.im + lhs.im * rhs.re)
        }
    }
}

/// Black and saturation codes for an 8-bit luma plane.
/// Video range (16 to 235) gets a saturation threshold the same distance below white as full range.
struct LumaCodeLevels: Sendable, Equatable {
    let black: Int
    let white: Int
    /// Codes at or above this count as saturated.
    let saturation: Int

    init(pixelFormat: UInt32) {
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            black = 16
            white = 235
        } else {
            black = 0
            white = 255
        }
        saturation = white - (255 - Int(CaptureStandard.saturationCode))
    }
}
