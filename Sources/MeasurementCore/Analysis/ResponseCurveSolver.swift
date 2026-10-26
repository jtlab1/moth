import CoreVideo
import Foundation

/// What the response sweep produced, kept for tests and diagnostics.
struct ResponseCurveSolution: Sendable {
    enum Model: Sendable, Equatable {
        /// ln F⁻¹(x) = Σ a_i u^i, i = 1…order, u = ln x: bends where a real tone curve bends.
        case polynomial(order: Int)
        /// F⁻¹(x) = x^γ: one number, used when the data can't support three.
        case gamma
    }

    let curve: ResponseCurve
    let model: Model
    /// RMS misfit in natural-log exposure.
    let rmsLogResidual: Double
    /// Normalised codes (0 = black, 1 = white) the sweep actually observed.
    let observedRange: ClosedRange<Double>
    let observationCount: Int
}

/// Inverse camera response from a short ISO sweep, by plain least squares.
///
/// ISO is a gain applied before the tone curve, so a patch of scene with exposure E seen at
/// gain g reads code c = F(g·E). Taking logs, ln F⁻¹(c) = ln E + ln g. Subtracting each
/// patch's mean over its steps removes the unknown E, leaving one linear equation per
/// observation in the curve's coefficients alone. At most five coefficients (one, for gamma)
/// means a handful of patches is plenty, nothing needs tuning, and it solves in milliseconds
/// on any phone. Codes are normalised as x = (c − black)/(white − black), so u = ln x is 0
/// at white and the curve is pinned at F⁻¹(white) = 1 with no extra parameter.
enum ResponseCurveSolver {

    /// Rows averaged into one patch: a defocused scene has no detail at this scale, and fewer,
    /// cleaner patches beat many noisy ones.
    static let patchRows = 8

    /// A patch-step is used only this far (codes) inside black and saturation.
    static let blackMarginCodes = 3.0

    /// Patch-steps needed to fit, and the extra a polynomial needs over gamma.
    static let minimumObservations = 12
    static let polynomialMinimumObservations = 60

    /// A polynomial is used only if the sweep saw at least this span of normalised codes;
    /// otherwise its bends would be guesses.
    static let polynomialMinimumSpan = 0.35

    /// Below this span of normalised codes the sweep says too little about the curve where
    /// measurements use it.
    static let minimumObservedSpan = 0.15

    /// Plausible gamma for an 8-bit display encoding (sRGB ≈ 2.2–2.4, Rec.709 ≈ 1.9–2.2).
    static let plausibleGamma: ClosedRange<Double> = 1.2...3.5

    /// Generous on purpose: real camera pipelines add noise reduction and mild local
    /// adaptation the model doesn't capture, and a curve with this misfit still recovers depth
    /// far better than none.
    static let maximumRMSLogResidual = 0.25

    static func solve(sweep: [FrameSequence]) throws -> ResponseCurveSolution {
        try Task.checkCancellation()
        guard let first = sweep.first else { throw unsolvable("no sweep steps were captured") }
        let levels = LumaCodeLevels(pixelFormat: first.metadata.pixelFormat)

        // Per step: its gain, and each patch's temporal mean code. The 29 fps phase drift
        // averages a mains flicker out over a step's frames.
        var logGains: [Double] = []
        var rowBlocks: [RowBlocks] = []
        for (index, sequence) in sweep.enumerated() {
            try Task.checkCancellation()
            guard let gain = Self.gain(of: sequence) else {
                throw unsolvable("sweep step \(index + 1) has no read-back ISO or exposure")
            }
            logGains.append(log(gain))
            rowBlocks.append(try Self.rowBlocks(of: sequence, levels: levels))
        }
        guard let rows = rowBlocks.map(\.rows).min(), let blocks = rowBlocks.map(\.blocks).min(), rows >= patchRows, blocks > 0,
              rowBlocks.allSatisfy({ $0.rows == rows && $0.blocks == blocks }) else {
            throw unsolvable("the sweep frames were empty or changed size")
        }

        // A hand-held phone drifts between steps; at an edge, a few rows of drift changes what
        // a patch sees. Each step is lined up with the middle one first, so patches compare
        // the same piece of scene rather than the same pixels.
        let order = logGains.indices.sorted { logGains[$0] < logGains[$1] }
        let referenceStep = order[order.count / 2]
        let referenceProfile = rowBlocks[referenceStep].edgeProfile(black: Double(levels.black))
        var steps: [Step] = []
        for index in rowBlocks.indices {
            let shift = index == referenceStep
                ? 0
                : Self.verticalShift(of: rowBlocks[index].edgeProfile(black: Double(levels.black)), against: referenceProfile)
            let patches = rowBlocks[index].patches(shift: shift)
            steps.append(Step(logGain: logGains[index], means: patches.means, clipped: patches.clipped, columns: blocks))
        }
        guard let patchCount = steps.map(\.means.count).min(), patchCount > 0 else {
            throw unsolvable("the sweep frames were empty")
        }
        guard (logGains.max() ?? 0) - (logGains.min() ?? 0) > log(1.5) else {
            throw unsolvable("the sweep's ISO steps were too close together to compare")
        }
        let smooth = smoothPatches(steps: steps, patchCount: patchCount, levels: levels)

        // All steps first. A hand-held sweep can have one step that disagrees with the rest
        // (a late exposure change, an ISO the camera didn't quite apply); if the whole sweep
        // doesn't fit, the best fit leaving one step out is taken instead.
        let all = Array(steps.indices)
        do {
            return try solve(steps: steps, using: all, patchCount: patchCount, smooth: smooth, levels: levels)
        } catch let firstError {
            guard steps.count >= 4 else { throw firstError }
            var best: ResponseCurveSolution?
            for left in all {
                try Task.checkCancellation()
                let using = all.filter { $0 != left }
                guard let candidate = try? solve(steps: steps, using: using, patchCount: patchCount, smooth: smooth, levels: levels) else { continue }
                if best == nil || candidate.rmsLogResidual < best!.rmsLogResidual { best = candidate }
            }
            if let best { return best }
            throw firstError
        }
    }

    struct Step {
        var logGain: Double
        var means: [Double]
        var clipped: [Bool]
        var columns: Int
    }

    typealias Observation = (u: Double, logGain: Double)

    /// A patch whose neighbours above and below differ from it by more than this (relative,
    /// in the middle step) sits on an edge, where hand movement between steps changes what it
    /// sees even after the steps are lined up.
    static let edgeContrast = 0.08

    /// Patches away from edges, judged on the step nearest the middle of the sweep. Every
    /// patch, if that would leave too few to fit (a scene that's all edges).
    static func smoothPatches(steps: [Step], patchCount: Int, levels: LumaCodeLevels) -> [Bool] {
        let sorted = steps.indices.sorted { steps[$0].logGain < steps[$1].logGain }
        let reference = steps[sorted[sorted.count / 2]]
        let columns = max(1, reference.columns)
        let black = Double(levels.black)
        var smooth = [Bool](repeating: false, count: patchCount)
        for patch in 0..<patchCount {
            let above = patch - columns
            let below = patch + columns
            guard above >= 0, below < patchCount else { continue }
            let level = reference.means[patch] - black
            guard level > 0 else { continue }
            // Vertical neighbours only: sideways ones also reject the smooth flanks of a lamp,
            // which carry the bright codes the curve's top needs.
            let contrast = max(
                abs(reference.means[above] - reference.means[patch]),
                abs(reference.means[below] - reference.means[patch])
            ) / level
            smooth[patch] = contrast <= edgeContrast
        }
        let smoothCount = smooth.filter { $0 }.count
        return smoothCount >= 4 * minimumObservations ? smooth : [Bool](repeating: true, count: patchCount)
    }

    static func solve(
        steps: [Step],
        using indices: [Int],
        patchCount: Int,
        smooth: [Bool],
        levels: LumaCodeLevels
    ) throws -> ResponseCurveSolution {
        let black = Double(levels.black)
        let range = Double(levels.white - levels.black)
        let ceiling = Double(levels.saturation) - blackMarginCodes

        // Observations, grouped by patch: (u = ln x, ln g) for each usable step.
        var groups: [[Observation]] = []
        for patch in 0..<patchCount where smooth[patch] {
            var group: [Observation] = []
            for step in indices {
                let code = steps[step].means[patch]
                // Any pixel at black or saturation in any frame drags the patch's mean
                // (the flicker's peaks clip first), so the whole patch-step goes.
                guard !steps[step].clipped[patch], code >= black + blackMarginCodes, code <= ceiling else { continue }
                group.append((log((code - black) / range), steps[step].logGain))
            }
            if let kept = usable(group) { groups.append(kept) }
        }
        let observationCount = groups.reduce(0) { $0 + $1.count }
        let codes = groups.flatMap { $0.map { exp($0.u) } }
        guard observationCount >= minimumObservations, let lowest = codes.min(), let highest = codes.max(), highest > lowest else {
            throw unsolvable(
                "only \(observationCount) usable patch readings; aim at a scene with both light and shade"
            )
        }
        let observedRange = lowest...highest
        guard highest - lowest >= minimumObservedSpan else {
            throw unsolvable(String(
                format: "the sweep only saw codes %.0f%%–%.0f%% of the range; aim at a brighter scene",
                lowest * 100, highest * 100
            ))
        }

        // The most flexible curve that stays monotone, down to gamma: a strongly S-shaped tone
        // curve needs the extra bends. Its wiggle where data thins out is handled by trusting
        // the fit only where readings are dense (`lookupTable`).
        var candidates: [(order: Int, fit: Polynomial)] = []
        if let gamma = robustFit(groups: groups, order: 1), plausibleGamma.contains(gamma.coefficients[0]) {
            candidates.append((1, gamma))
        }
        if observationCount >= polynomialMinimumObservations, highest - lowest >= polynomialMinimumSpan {
            for order in [3, 4, 5] {
                if let polynomial = robustFit(groups: groups, order: order),
                   isMonotone(polynomial.coefficients, from: lowest) {
                    candidates.append((order, polynomial))
                }
            }
        }
        guard let chosen = candidates.last else {
            throw unsolvable("the camera's response didn't look like any display encoding")
        }
        return try makeSolution(
            chosen.fit,
            model: chosen.order == 1 ? .gamma : .polynomial(order: chosen.order),
            observedRange: observedRange,
            observations: observationCount,
            observedCodes: codes,
            levels: levels
        )
    }

    /// A patch's observations if they span distinct gains; nil if they say nothing about the curve.
    static func usable(_ group: [Observation]) -> [Observation]? {
        let gains = group.map(\.logGain)
        guard group.count >= 2, (gains.max() ?? 0) - (gains.min() ?? 0) > log(1.5) else { return nil }
        return group
    }

    /// Readings further than this many robust standard deviations from the fit are dropped
    /// and the curve refitted: a patch the hand moved across, a reflection that came and went.
    static let outlierSigma = 3.0

    /// The fit, then up to two refits without its outliers. Never drops more than a quarter of
    /// the readings: if that many disagree, the misfit should say so.
    static func robustFit(groups: [[Observation]], order: Int) -> Polynomial? {
        guard var current = fit(groups: groups, order: order) else { return nil }
        var kept = groups
        let total = groups.reduce(0) { $0 + $1.count }
        for _ in 0..<2 {
            let misfits = kept.flatMap { residuals(of: $0, coefficients: current.coefficients) }
            let deviations = misfits.map { abs($0) }.sorted()
            guard !deviations.isEmpty else { break }
            let sigma = max(0.01, 1.4826 * deviations[deviations.count / 2])
            let limit = outlierSigma * sigma
            var trimmed: [[Observation]] = []
            for group in kept {
                let groupResiduals = residuals(of: group, coefficients: current.coefficients)
                let filtered = zip(group, groupResiduals).filter { abs($0.1) <= limit }.map(\.0)
                if let usable = usable(filtered) { trimmed.append(usable) }
            }
            let remaining = trimmed.reduce(0) { $0 + $1.count }
            guard remaining < kept.reduce(0, { $0 + $1.count }), remaining * 4 >= total * 3,
                  remaining >= minimumObservations,
                  let refit = fit(groups: trimmed, order: order) else { break }
            kept = trimmed
            current = refit
        }
        return current
    }

    /// Each observation's misfit, in log exposure, after its patch's own exposure is fitted.
    static func residuals(of group: [Observation], coefficients a: [Double]) -> [Double] {
        func curve(_ u: Double) -> Double {
            var power = 1.0
            var sum = 0.0
            for coefficient in a {
                power *= u
                sum += coefficient * power
            }
            return sum
        }
        // ln E_p = mean(ln F⁻¹(x) − ln g) over the patch's steps.
        let offsets = group.map { curve($0.u) - $0.logGain }
        let mean = offsets.reduce(0, +) / Double(max(1, offsets.count))
        return offsets.map { $0 - mean }
    }

    // MARK: Fit

    struct Polynomial {
        /// a₁…a_order: ln F⁻¹ = Σ a_i u^i.
        var coefficients: [Double]
        var rmsLogResidual: Double
    }

    /// Least squares on Σ_i a_i (u^i − ū^i_p) = ln g − mean_p(ln g), ū_p the patch's mean.
    static func fit(groups: [[Observation]], order: Int) -> Polynomial? {
        var normal = [Double](repeating: 0, count: order * order)
        var rhs = [Double](repeating: 0, count: order)
        var rows: [([Double], Double)] = []
        for group in groups {
            let count = Double(group.count)
            var meanPowers = [Double](repeating: 0, count: order)
            var meanLogGain = 0.0
            let powers = group.map { observation -> [Double] in
                var value = 1.0
                return (0..<order).map { _ in value *= observation.u; return value }
            }
            for (index, observation) in group.enumerated() {
                for i in 0..<order { meanPowers[i] += powers[index][i] / count }
                meanLogGain += observation.logGain / count
            }
            for (index, observation) in group.enumerated() {
                let row = (0..<order).map { powers[index][$0] - meanPowers[$0] }
                let target = observation.logGain - meanLogGain
                for i in 0..<order {
                    rhs[i] += row[i] * target
                    for k in 0..<order { normal[i * order + k] += row[i] * row[k] }
                }
                rows.append((row, target))
            }
        }
        guard let coefficients = solveLinear(normal, rhs, size: order) else { return nil }
        var squares = 0.0
        for (row, target) in rows {
            let predicted = zip(row, coefficients).reduce(0) { $0 + $1.0 * $1.1 }
            squares += (predicted - target) * (predicted - target)
        }
        let dof = max(1, rows.count - groups.count - order)
        return Polynomial(coefficients: coefficients, rmsLogResidual: (squares / Double(dof)).squareRoot())
    }

    /// d ln F⁻¹ / du > 0 from the lowest observed code to white, so brighter always maps to
    /// more light.
    static func isMonotone(_ a: [Double], from lowest: Double) -> Bool {
        let low = log(max(lowest, 1e-6))
        return (0...64).allSatisfy { index in
            let u = low * Double(index) / 64
            var slope = 0.0
            for (i, coefficient) in a.enumerated() { slope += Double(i + 1) * coefficient * pow(u, Double(i)) }
            return slope > 0.2
        }
    }

    // MARK: Curve

    static func makeSolution(
        _ fit: Polynomial,
        model: ResponseCurveSolution.Model,
        observedRange: ClosedRange<Double>,
        observations: Int,
        observedCodes: [Double],
        levels: LumaCodeLevels
    ) throws -> ResponseCurveSolution {
        guard fit.rmsLogResidual <= maximumRMSLogResidual else {
            throw unsolvable(String(
                format: "the readings didn't fit one response curve (misfit %.2f, limit %.2f)",
                fit.rmsLogResidual, maximumRMSLogResidual
            ))
        }
        return ResponseCurveSolution(
            curve: try lookupTable(fit.coefficients, observedCodes: observedCodes, levels: levels),
            model: model,
            rmsLogResidual: fit.rmsLogResidual,
            observedRange: observedRange,
            observationCount: observations
        )
    }

    /// Share of readings at each end of the observed codes where the fit is not trusted on its
    /// own: readings thin out there, and a polynomial wanders where data is thin.
    static let trustedQuantile = 0.03

    /// The fitted curve where readings are dense (the `trustedQuantile` to 1 − that quantile
    /// of observed codes). Beyond that it continues as a straight line in log–log (a local
    /// power law) whose slope is the average over the next stretch of dense data, not the
    /// derivative at one edge point. 0 at black; normalised so the brightest code is 1 (only
    /// ratios matter downstream).
    static func lookupTable(_ a: [Double], observedCodes: [Double], levels: LumaCodeLevels) throws -> ResponseCurve {
        func logCurve(_ u: Double) -> Double {
            a.enumerated().reduce(0) { $0 + $1.element * pow(u, Double($1.offset + 1)) }
        }
        let sorted = observedCodes.filter { $0 > 0 }.sorted()
        guard sorted.count >= 2 else { throw unsolvable("too few readings to build the curve") }
        func quantile(_ q: Double) -> Double {
            log(sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * q)))])
        }
        let low = quantile(trustedQuantile)
        let lowInner = quantile(trustedQuantile * 4)
        let high = quantile(1 - trustedQuantile)
        let highInner = quantile(1 - trustedQuantile * 4)
        func secant(_ u0: Double, _ u1: Double) -> Double {
            guard abs(u1 - u0) > 1e-6 else { return 2.2 }
            return min(max((logCurve(u1) - logCurve(u0)) / (u1 - u0), 1), plausibleGamma.upperBound)
        }
        let lowSlope = secant(low, lowInner)
        let highSlope = secant(highInner, high)
        let black = Double(levels.black)
        let range = Double(levels.white - levels.black)
        var values: [Double] = []
        var running = 0.0
        for code in 0..<ResponseCurve.entryCount {
            let x = (Double(code) - black) / range
            var value = 0.0
            if x > 0 {
                let u = log(x)
                if u < low {
                    value = exp(logCurve(low) + lowSlope * (u - low))
                } else if u > high {
                    value = exp(logCurve(high) + highSlope * (u - high))
                } else {
                    value = exp(logCurve(u))
                }
            }
            running = max(running, value.isFinite ? value : running)
            values.append(running)
        }
        let top = values.last ?? 1
        guard top > 0 else { throw unsolvable("the fitted curve was flat") }
        return try ResponseCurve(values: values.map { Float($0 / top) })
    }

    // MARK: Data

    /// Median read-back ISO × exposure over the step's frames: the gain the step ran at.
    static func gain(of sequence: FrameSequence) -> Double? {
        let gains = sequence.metadata.frames
            .map { Double($0.iso) * $0.exposureDuration }
            .filter { $0 > 0 && $0.isFinite }
            .sorted()
        guard !gains.isEmpty else { return nil }
        return gains[gains.count / 2]
    }

    /// A frame whose overall brightness is this far (relative) from the settled level is
    /// dropped: it was exposed before the step's ISO took effect. Steps are a stop apart, so a
    /// stale frame is 25%+ off in code; the light's own flicker moves frames only ~5%, and
    /// must not be filtered, or the dim half of its cycle would be dropped and bias the mean.
    static let frameBrightnessTolerance = 0.15

    /// One step's mean code per (row, column block) over its kept frames, and whether any pixel
    /// there sat at black or saturation. Kept per row, not per patch, so the step can be lined
    /// up with the others row by row before patches are formed.
    struct RowBlocks {
        let rows: Int
        let blocks: Int
        /// Row-major, `rows × blocks`.
        let means: [Double]
        let clipped: [Bool]

        /// High-passed log row profile: edges, independent of the step's gain and of the
        /// tone curve's slope (a monotone curve keeps edges where they are).
        func edgeProfile(black: Double) -> [Double] {
            let logs = (0..<rows).map { y -> Double in
                var sum = 0.0
                for block in 0..<blocks { sum += means[y * blocks + block] }
                return log(max(sum / Double(blocks) - black, 0.5))
            }
            let half = 16
            var prefix = [0.0]
            for value in logs { prefix.append(prefix.last! + value) }
            return (0..<rows).map { y in
                let low = max(0, y - half)
                let high = min(rows, y + half + 1)
                return logs[y] - (prefix[high] - prefix[low]) / Double(high - low)
            }
        }

        /// Patches of `patchRows` rows × one block, in the reference step's coordinates: the
        /// patch at reference rows y… is read from this step's rows y + shift…. Patches that
        /// fall off the frame are marked clipped (unusable).
        func patches(shift: Int) -> (means: [Double], clipped: [Bool]) {
            let bands = rows / patchRows
            var patchMeans = [Double](repeating: 0, count: bands * blocks)
            var patchClipped = [Bool](repeating: true, count: bands * blocks)
            for band in 0..<bands {
                let start = band * patchRows + shift
                guard start >= 0, start + patchRows <= rows else { continue }
                for block in 0..<blocks {
                    var sum = 0.0
                    var clipped = false
                    for y in start..<(start + patchRows) {
                        sum += means[y * blocks + block]
                        clipped = clipped || self.clipped[y * blocks + block]
                    }
                    patchMeans[band * blocks + block] = sum / Double(patchRows)
                    patchClipped[band * blocks + block] = clipped
                }
            }
            return (patchMeans, patchClipped)
        }
    }

    /// Largest drift (fraction of the frame height) searched between steps.
    static let maximumShiftFraction = 0.2

    /// The lag d (rows) that best lines `profile` up with `reference`: the scene at reference
    /// row y is at row y + d here. 0 when the scene has no edges to line up (a flat wall),
    /// where drift doesn't matter anyway.
    static func verticalShift(of profile: [Double], against reference: [Double]) -> Int {
        let rows = min(profile.count, reference.count)
        let limit = Int(Double(rows) * maximumShiftFraction)
        var best = (lag: 0, score: -Double.infinity)
        for lag in -limit...limit {
            var dot = 0.0
            var a = 0.0
            var b = 0.0
            for y in max(0, -lag)..<min(rows, rows - lag) {
                let r = reference[y]
                let p = profile[y + lag]
                dot += r * p
                a += r * r
                b += p * p
            }
            guard a > 0, b > 0 else { continue }
            let score = dot / (a * b).squareRoot()
            if score > best.score { best = (lag, score) }
        }
        return best.score >= 0.5 ? best.lag : 0
    }

    static func rowBlocks(of sequence: FrameSequence, levels: LumaCodeLevels) throws -> RowBlocks {
        var frameSums: [[Double]] = []
        var frameClipped: [[Bool]] = []
        var rows = 0
        var blocks = 0
        var blockWidth = 1
        let floor = UInt8(clamping: levels.black + 1)
        let ceiling = UInt8(clamping: levels.saturation)
        try sequence.forEachPlane { index, plane, _ in
            if index % 8 == 0 { try Task.checkCancellation() }
            if frameSums.isEmpty {
                blockWidth = max(1, min(CaptureStandard.responsePatchColumnWidth, plane.width))
                rows = plane.height
                blocks = plane.width / blockWidth
            }
            guard plane.height == rows, plane.width / blockWidth == blocks, rows * blocks > 0 else { return }
            var sums = [Double](repeating: 0, count: rows * blocks)
            var clipped = [Bool](repeating: false, count: rows * blocks)
            for y in 0..<rows {
                let row = plane.rowBytes(y)
                for x in 0..<(blocks * blockWidth) {
                    let cell = y * blocks + x / blockWidth
                    let value = row[x]
                    sums[cell] += Double(value)
                    if value <= floor || value >= ceiling { clipped[cell] = true }
                }
            }
            frameSums.append(sums)
            frameClipped.append(clipped)
        }
        guard !frameSums.isEmpty else { return RowBlocks(rows: 0, blocks: 0, means: [], clipped: []) }

        // The reference is the second half's median: a late exposure change only ever
        // affects the first frames, so the end of the step is what it settled to.
        let totals = frameSums.map { $0.reduce(0, +) }
        let settled = totals.suffix(max(1, totals.count / 2)).sorted()
        let reference = settled[settled.count / 2]
        var kept = totals.indices.filter { reference > 0 && abs(totals[$0] / reference - 1) <= frameBrightnessTolerance }
        if kept.count * 4 < totals.count { kept = Array(totals.indices) }

        var means = [Double](repeating: 0, count: rows * blocks)
        var clipped = [Bool](repeating: false, count: rows * blocks)
        for frame in kept {
            for cell in 0..<(rows * blocks) {
                means[cell] += frameSums[frame][cell]
                if frameClipped[frame][cell] { clipped[cell] = true }
            }
        }
        let perCell = Double(blockWidth * kept.count)
        return RowBlocks(rows: rows, blocks: blocks, means: means.map { $0 / perCell }, clipped: clipped)
    }

    /// Gaussian elimination with partial pivoting; nil if singular.
    static func solveLinear(_ matrix: [Double], _ vector: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var b = vector
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
            guard abs(a[pivot * n + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<n { a.swapAt(pivot * n + k, column * n + k) }
                b.swapAt(pivot, column)
            }
            for row in (column + 1)..<n {
                let factor = a[row * n + column] / a[column * n + column]
                for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in (0..<n).reversed() {
            var value = b[row]
            for k in (row + 1)..<n { value -= a[row * n + k] * x[k] }
            x[row] = value / a[row * n + row]
        }
        return x
    }

    static func unsolvable(_ reason: String) -> AnalysisError {
        .responseCurveUnsolvable(reason: reason)
    }
}
