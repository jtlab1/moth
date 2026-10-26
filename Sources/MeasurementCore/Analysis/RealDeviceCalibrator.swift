import CoreVideo
import Foundation

/// The analyzer run in reverse: the frequency is known, the readout time isn't.
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

        // The signature `MeasurementRunner` validates against, so both agree on what's plausible.
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

    /// Debevec–Malik over the ISO sweep; see `ResponseCurveSolver`.
    public func solveResponseCurve(from sweep: [FrameSequence]) async throws -> ResponseCurve {
        try Task.checkCancellation()
        return try ResponseCurveSolver.solve(sweep: sweep).curve
    }
}

// MARK: - Readout solver

/// What the readout search found, kept for tests and diagnostics.
struct ReadoutSolution: Sendable {
    let lineReadoutTime: TimeInterval

    /// Peak power over the noise power expected at the same readout time, measured from this
    /// capture's own fit residuals (hand sway included). About 1 for no flicker at all.
    let significance: Double

    /// What `significance` had to reach: pure noise clears it once in
    /// `1 / falseAlarmProbability` captures, given how many readout times were searched.
    let significanceThreshold: Double

    /// The `k` of the sub-multiple the harmonic guard moved to, if it fired.
    let harmonicGuardDivisor: Int?
    let usableRowFraction: Double
}

/// Searches line readout time `L` directly. Each row of each frame samples the light at
/// `t_f + y·L`; for a candidate `L` the model is one waveform at the known frequency (and its
/// 2nd and 3rd harmonics) seen through every frame at once, so the frames' real timestamps
/// do the work. Coherent across frames, it needs no full cycle within a frame and can't lock
/// onto a harmonic: a 2F component drifts at twice the per-frame phase rate of F, so it
/// doesn't add up under F's demodulation, whatever `L` is tried.
///
/// Deviation from the spec's incoherent first stage: per-frame power can't resolve a
/// pattern spanning under ~2 cycles and is what invites harmonic lock-on, so the grid is
/// searched coherently from the start. It's cheap: each block is fitted across frames once, and
/// each candidate `L` then costs one pass over ~128 row blocks.
enum ReadoutSolver {

    /// The fundamental plus the harmonics a magnetic ballast adds; all of them carry `L`.
    static let harmonicCount = 3

    /// Rows are averaged into this many blocks: the highest pattern searched is ~13 cycles per
    /// frame, so ~128 blocks lose nothing and cut the work ~8×.
    static let targetBlockCount = 128

    /// Columns sampled per row; the row mean of a defocused scene needs no more.
    static let maximumSampledColumns = 256

    static let minimumFrameCount = 8

    /// Searching past the plausible ceiling means an out-of-range readout is found and refused,
    /// rather than clipped to the boundary and accepted.
    static let searchCeilingFactor = 2.0

    /// Grid steps per main-lobe width of the highest harmonic.
    static let gridOversampling = 6.0

    /// A row is unusable if its temporal mean is within this many codes of black.
    static let minimumRowSignalCodes: Float = 4

    /// Chance that a capture with no flicker at all passes the significance test.
    static let falseAlarmProbability = 1e-3

    /// Residual noise is also measured at temporal frequencies this close (Hz) to each
    /// harmonic's alias, so noise concentrated there (hand tremor) isn't averaged away.
    static let localNoiseOffsetsHz: [Double] = [-3, -2.5, -2, -1.5, 1.5, 2, 2.5, 3]

    /// Offsets closer than this (Hz, after aliasing) to a fitted term see a residual the fit
    /// has already zeroed, which would understate the noise.
    static let localNoiseClearanceHz = 1.0

    static func solve(
        frames: FrameSequence,
        frequencyHz: Double,
        plausible: ClosedRange<TimeInterval>
    ) throws -> ReadoutSolution {
        guard frames.count >= minimumFrameCount else {
            throw AnalysisError.tooFewFrames(captured: frames.count, required: minimumFrameCount)
        }
        // The whole method rests on the light's phase drifting from frame to frame; a camera
        // running in step with it (30 fps under 120 Hz) shows the same pattern every frame,
        // which the flat field then removes. Refuse that plainly instead of as "no signal".
        let frameRate = estimatedFrameRate(frames.metadata)
        let drift = phaseDriftCycles(frequencyHz: frequencyHz, frameRate: frameRate, frameCount: frames.count)
        guard drift >= minimumPhaseDriftCycles else {
            throw AnalysisError.frameRateLockedToLight(frameRate: frameRate, lightHz: frequencyHz)
        }

        let data = try RatioBlocks(frames: frames)
        try Task.checkCancellation()

        let search = Search(data: data, frequencyHz: frequencyHz, frameRate: frameRate)

        // Stage 1: coherent power on a uniform grid. The lobe width in L is fixed by rows
        // and frequency, so a uniform grid (not a log one) samples every lobe equally.
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

        // Readout direction: a negative L is the sensor reading the buffer's last row first.
        // The analyzer assumes row 0 first, and a reversed pattern can line up with a wrong
        // positive L well enough to pass every other check, so a stronger mirrored peak is
        // refused rather than solved.
        var reversed = (L: -lower, power: 0.0)
        for index in 0..<gridCount {
            if index % 64 == 0 { try Task.checkCancellation() }
            let L = -(lower + Double(index) * gridStep)
            let power = search.evaluate(L)
            if power > reversed.power { reversed = (L, power) }
        }

        // Stage 2: coherent refine between the neighbouring grid points.
        var best = search.refine(around: grid[bestIndex].L, halfWidth: gridStep, floor: lower)

        // Significance against this capture's own noise at the solved readout time, not
        // against other readout times or off-frequency probes: picking the best of thousands
        // of candidates always looks impressive, and probes near hand-sway frequencies
        // don't. Searching both directions doubles the trials the threshold allows for.
        let trials = 2 * max(1, (upper - lower) / search.lobeWidth(harmonic: harmonicCount))
        let threshold = significanceThreshold(trials: trials, harmonics: harmonicCount)
        let significance = best.power / search.noisePower(at: best.L)

        // The mirrored peak must pass the same test a real one does, or noise alone (a
        // steady light) would read as a reversed sensor.
        if reversed.power > best.power, reversed.power / search.noisePower(at: reversed.L) >= threshold {
            throw AnalysisError.readoutDirectionReversed
        }

        guard significance >= threshold else {
            throw AnalysisError.referenceFlickerNotFound(
                reason: "flicker at \(Int(frequencyHz.rounded())) Hz was "
                    + String(format: "%.1f× the measured noise floor; needs %.1f×", significance, threshold)
            )
        }

        // Harmonic guard: a sub-multiple L*/k with comparable power means L* may be a
        // harmonic lock-on; take the smallest such. Only sub-multiples resolvable from L*
        // are tested, or the peak's own lobe would always trip it.
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

    /// Below two cycles of drift across the capture, the fit across frames can't separate the
    /// flicker from the scene and the slow-drift terms it fits alongside.
    static let minimumPhaseDriftCycles = 2.0

    /// Noise-only significance is power summed over `harmonics` complex amplitudes, each
    /// exponentially distributed, over its mean: Gamma(K, 1/K). The threshold `x` solves
    /// trials · P(Gamma(K) > K·x) = falseAlarmProbability.
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

    /// How many cycles the reference's phase drifts, frame to frame, over the whole capture:
    /// the distance of F/fps from the nearest whole number, times the frame count.
    static func phaseDriftCycles(frequencyHz: Double, frameRate: Double, frameCount: Int) -> Double {
        guard frameRate > 0, frequencyHz > 0 else { return 0 }
        let cyclesPerFrame = frequencyHz / frameRate
        let offset = abs(cyclesPerFrame - cyclesPerFrame.rounded())
        return offset * Double(frameCount)
    }

    /// 1 / median presentation-time delta; the nominal rate if timestamps are unusable.
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

    /// Each row block's complex amplitude at every harmonic of the known frequency, fitted
    /// across all frames (`fitSinusoids`). The frames drift through the flicker's phase,
    /// so this needs nothing from within a frame, and the result's phase is
    /// k·2πF·L·y_j + const whatever the block's brightness or tone-curve slope (which only
    /// scale its magnitude). Searching L is then fitting that phase slope.
    struct Search {
        let frequencyHz: Double
        private let rows: [Double]
        private let weights: [Double]
        private let rowSpan: Double
        /// [harmonic][block]
        private let signal: [[Complex]]
        /// What the fit left, frame-major: noise, hand sway, anything not the light.
        private let residuals: [Double]
        private let times: [Double]
        private let frameCount: Int
        /// Per harmonic, Σ_f |hat_f|² for its complex amplitude: how residual noise on each
        /// frame propagates into that amplitude.
        private let coefficientVariance: [Double]
        private let degreesOfFreedom: Double
        /// Per harmonic, the temporal offsets (Hz) local noise is measured at.
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

        /// Trend columns: slow drift (hand sway, a lamp warming up) is fitted out rather than
        /// left in the residual, where it would inflate the noise the flicker is judged against.
        static let trendTerms = 2

        /// Per block, least squares over frames of
        /// r = c₀ + c₁τ + c₂τ² + Σ_m (a_m cos 2πf_m t + b_m sin 2πf_m t), τ the centred,
        /// scaled time. Fitting jointly, rather than correlating with each phasor, removes
        /// the leakage between harmonics and from each one's mirror image that a few seconds of
        /// unevenly drifting phase leaves: at under a cycle per frame that leakage would bend
        /// the phase slope by several percent.
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
            // A whisker of ridge keeps a degenerate timing (phases not drifting) solvable;
            // the fit is then simply weak, never wrong.
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

        /// Width in L of the coherent peak's main lobe for harmonic `k`: one extra cycle
        /// across the usable rows.
        func lobeWidth(harmonic k: Int) -> Double {
            1 / (Double(k) * frequencyHz * max(rowSpan, 1))
        }

        /// Σ_k |Σ_j w_j c_jk e^{-ik·2πF·L·y_j}|²: all blocks' phases lined up by L. A negative
        /// L is a sensor reading the last row first.
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

        /// The power `evaluate(L)` would show from noise alone. The residuals are combined
        /// across blocks exactly as the signal is at this L, so noise shared between blocks
        /// (the whole scene swaying) counts at its true strength. Per harmonic, the larger of
        /// the average residual power and the residual power near that harmonic's alias
        /// frequency, so tremor concentrated at one frequency isn't averaged away.
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
                // Z_f: this frame's residual, combined across blocks the way the signal is.
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
                // Local: |Σ_f Z_f e^{-i2π(kF+δ)t_f}|² / n estimates the same per-frame power,
                // but at temporal frequencies next to this harmonic's.
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

        /// Golden-section maximum within ±`halfWidth`; the peak is smooth at this scale.
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

        /// Temporal offsets (Hz) from `hz` whose aliases stay `localNoiseClearanceHz` clear of
        /// every fitted term: each harmonic (both signs) and the slow-drift terms near 0 Hz.
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

    /// Flat-field-normalised, row-block-averaged samples.
    ///
    /// Each row is divided by its own temporal mean, which removes the scene (lamp blob,
    /// vignetting, aim) without touching low spatial frequencies the way skipping bins would;
    /// the 29 fps phase drift is what makes the temporal mean flicker-free.
    struct RatioBlocks {
        let frameCount: Int
        let blockCount: Int
        /// Mean row index of each block's usable rows.
        let rows: [Double]
        /// Usable rows per block.
        let weights: [Double]
        /// r − 1 per block, frame-major. Not detrended: per-frame offsets and slopes (hand
        /// shake, exposure wobble) aren't periodic at F, so demodulation already rejects them,
        /// while detrending would strip most of a pattern spanning under one cycle.
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

            // Flat field and row exclusion (spec C2's rules, applied here privately).
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

/// Black and saturation codes for an 8-bit luma plane. Video range puts black at 16 and
/// white at 235, so its saturation threshold sits as far below 235 as the full-range one
/// sits below 255.
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
