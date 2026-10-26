import Accelerate
import Foundation

/// A capture divided, row by row, by that row's own temporal mean (spec C2).
///
/// At the standard 29 fps, mains-family flicker drifts in phase from frame to frame, so a
/// row's mean over the capture is the scene's brightness at that row with the flicker averaged
/// out. Dividing by it leaves `r = 1 + flicker` in every usable row whatever the lamp shape,
/// vignetting, aim, ISO or (with a response curve) tone curve. Frequency and depth both work on
/// `r`, which is what makes them comparable across phones.
///
/// Shared by `RealFlickerAnalyzer` and `RealDeviceCalibrator`; module-internal on purpose.
struct FlatFieldCapture: Sendable {
    let rowCount: Int

    /// One per frame, each `rowCount` long: `r(row, frame) = v / M(row)`. Excluded rows hold
    /// exactly 1, so `r - 1` is 0 there and contributes nothing to any sum or spectrum.
    let ratios: [[Float]]

    /// `M(row)` in the capture's units (linear or code); 0 for excluded rows.
    let rowMeans: [Float]

    /// Rows that are neither saturated nor crushed.
    let usableRows: [Bool]
    let usableRowCount: Int
    let saturatedRowCount: Int
    let crushedRowCount: Int

    /// Mirrors `RowBrightnessFrame`, so callers needn't keep the extracted capture alive.
    let presentationTimes: [TimeInterval]
    let exposureDurations: [TimeInterval]
    let isos: [Float]
    let exposureModes: [ExposureMode]
    let isLinear: Bool

    var frameCount: Int { ratios.count }
    var usableFraction: Double { rowCount > 0 ? Double(usableRowCount) / Double(rowCount) : 0 }

    /// The same capture with each row's ratio divided by `factors[row]`, i.e. with M(row)
    /// multiplied by it. For refining M once a model of the flicker exists.
    func rescalingRows(by factors: [Float]) -> FlatFieldCapture {
        precondition(factors.count == rowCount)
        let inverse = factors.map { $0 > 0 ? 1 / $0 : 1 }
        let rescaled = ratios.map { ratio in
            var result = [Float](repeating: 1, count: rowCount)
            vDSP_vmul(ratio, 1, inverse, 1, &result, 1, vDSP_Length(rowCount))
            return result
        }
        var means = rowMeans
        vDSP_vmul(rowMeans, 1, factors, 1, &means, 1, vDSP_Length(rowCount))
        return FlatFieldCapture(
            rowCount: rowCount,
            ratios: rescaled,
            rowMeans: means,
            usableRows: usableRows,
            usableRowCount: usableRowCount,
            saturatedRowCount: saturatedRowCount,
            crushedRowCount: crushedRowCount,
            presentationTimes: presentationTimes,
            exposureDurations: exposureDurations,
            isos: isos,
            exposureModes: exposureModes,
            isLinear: isLinear
        )
    }

    /// `r - 1` per frame (0 on excluded rows): the zero-mean signal spectra are taken of.
    func deviations() -> [[Float]] {
        ratios.map { ratio in
            var deviation = [Float](repeating: 0, count: rowCount)
            var minusOne: Float = -1
            vDSP_vsadd(ratio, 1, &minusOne, &deviation, 1, vDSP_Length(rowCount))
            return deviation
        }
    }
}

enum FlatField {

    /// A row whose temporal mean raw code is within this many codes of nominal black carries
    /// mostly quantisation and read noise; its ratio would be noise divided by noise.
    static let crushedCodeMargin: Float = 4

    /// - Parameter frameGains: per-frame relative gain (ISO × exposure over its median), divided
    ///   out before the row means. Only meaningful for linear captures; pass `nil` otherwise.
    /// - Throws: `sensorSaturated` or `insufficientSignal` when fewer than
    ///   `CaptureStandard.minimumUsableRowFraction` of rows are usable, whichever exclusion
    ///   dominates.
    static func normalise(_ capture: RowBrightnessCapture, frameGains: [Double]? = nil) throws -> FlatFieldCapture {
        let rowCount = capture.rowCount
        let frames = capture.frames
        guard rowCount > 0, !frames.isEmpty else {
            throw AnalysisError.insufficientSignal(reason: "no rows to normalise")
        }

        // Gain-corrected rows, then M(row) as their mean over frames.
        var corrected: [[Float]] = frames.map(\.rowBrightness)
        if let frameGains, frameGains.count == frames.count {
            for index in corrected.indices where frameGains[index] > 0 && frameGains[index] != 1 {
                var scale = Float(1 / frameGains[index])
                vDSP_vsmul(corrected[index], 1, &scale, &corrected[index], 1, vDSP_Length(rowCount))
            }
        }
        var sums = [Float](repeating: 0, count: rowCount)
        for rows in corrected where rows.count == rowCount {
            vDSP_vadd(sums, 1, rows, 1, &sums, 1, vDSP_Length(rowCount))
        }
        var means = sums
        var divisor = Float(corrected.count)
        vDSP_vsdiv(sums, 1, &divisor, &means, 1, vDSP_Length(rowCount))

        var usable = [Bool](repeating: false, count: rowCount)
        var saturatedRows = 0
        var crushedRows = 0
        for row in 0..<rowCount {
            if capture.rowSaturated[row] {
                saturatedRows += 1
            } else if capture.rowMeanCodes[row] - capture.blackPointCode <= crushedCodeMargin
                || capture.rowBlackClipped[row]
                || !(means[row] > 0) || !means[row].isFinite {
                crushedRows += 1
            } else {
                usable[row] = true
            }
        }
        let usableCount = usable.lazy.filter { $0 }.count

        if Double(usableCount) < CaptureStandard.minimumUsableRowFraction * Double(rowCount) {
            if saturatedRows >= crushedRows {
                throw AnalysisError.sensorSaturated
            }
            throw AnalysisError.insufficientSignal(
                reason: "only \(usableCount) of \(rowCount) rows were bright enough to measure"
            )
        }

        // r = v / M on usable rows, exactly 1 elsewhere: r = mask · (v · 1/M) + (1 − mask).
        var mask = [Float](repeating: 0, count: rowCount)
        var inverseMeans = [Float](repeating: 0, count: rowCount)
        for row in 0..<rowCount where usable[row] {
            mask[row] = 1
            inverseMeans[row] = 1 / means[row]
        }
        var complement = [Float](repeating: 1, count: rowCount)
        vDSP_vsub(mask, 1, complement, 1, &complement, 1, vDSP_Length(rowCount))

        var ratios: [[Float]] = []
        ratios.reserveCapacity(corrected.count)
        for rows in corrected {
            var ratio = [Float](repeating: 1, count: rowCount)
            if rows.count == rowCount {
                vDSP_vmul(rows, 1, inverseMeans, 1, &ratio, 1, vDSP_Length(rowCount))
                vDSP_vadd(ratio, 1, complement, 1, &ratio, 1, vDSP_Length(rowCount))
            }
            ratios.append(ratio)
        }
        for row in 0..<rowCount where !usable[row] { means[row] = 0 }

        return FlatFieldCapture(
            rowCount: rowCount,
            ratios: ratios,
            rowMeans: means,
            usableRows: usable,
            usableRowCount: usableCount,
            saturatedRowCount: saturatedRows,
            crushedRowCount: crushedRows,
            presentationTimes: frames.map(\.presentationTime),
            exposureDurations: frames.map(\.exposureDuration),
            isos: frames.map(\.iso),
            exposureModes: frames.map(\.exposureMode),
            isLinear: capture.isLinear
        )
    }

    /// Per-frame least-squares line over the usable rows of a deviation (`r - 1`), with the
    /// row index as abscissa. Build once per capture; `detrend` and `trend` are then a few vDSP
    /// calls per frame.
    struct Detrender: Sendable {
        let mask: [Float]
        /// Row coordinate scaled to −1...1 across the buffer, so slopes are "change across the frame".
        let abscissa: [Float]
        private let determinant: Double
        private let sumWeights: Double
        private let sumAbscissa: Double
        private let sumAbscissaSquared: Double

        init(usableRows: [Bool]) {
            let count = usableRows.count
            mask = usableRows.map { $0 ? 1 : 0 }
            let scale = count > 1 ? 2 / Float(count - 1) : 0
            abscissa = (0..<count).map { Float($0) * scale - 1 }
            var weights: Double = 0, sx: Double = 0, sxx: Double = 0
            for row in 0..<count where usableRows[row] {
                let x = Double(abscissa[row])
                weights += 1
                sx += x
                sxx += x * x
            }
            sumWeights = weights
            sumAbscissa = sx
            sumAbscissaSquared = sxx
            determinant = weights * sxx - sx * sx
        }

        /// `deviation` must already be 0 on excluded rows (as `FlatFieldCapture.deviations()` is).
        /// `offset` is the fitted value at mid-frame, `slope` the change from mid to last row.
        func trend(_ deviation: [Float]) -> (offset: Double, slope: Double) {
            guard sumWeights > 1, determinant > 0 else { return (0, 0) }
            var sy: Float = 0
            var sxy: Float = 0
            vDSP_sve(deviation, 1, &sy, vDSP_Length(deviation.count))
            vDSP_dotpr(deviation, 1, abscissa, 1, &sxy, vDSP_Length(deviation.count))
            let slope = (sumWeights * Double(sxy) - sumAbscissa * Double(sy)) / determinant
            let intercept = (Double(sy) - slope * sumAbscissa) / sumWeights
            return (intercept, slope)
        }

        /// Removes each frame's own line, for detection only: a per-frame offset or tilt
        /// (hand motion, ISO wobble) would otherwise leak into every low bin. Excluded rows stay 0.
        func detrend(_ deviation: [Float]) -> [Float] {
            let (offset, slope) = trend(deviation)
            var line = [Float](repeating: 0, count: deviation.count)
            var a = Float(-slope)
            var b = Float(-offset)
            vDSP_vsmsa(abscissa, 1, &a, &b, &line, 1, vDSP_Length(deviation.count))
            var result = [Float](repeating: 0, count: deviation.count)
            vDSP_vma(line, 1, mask, 1, deviation, 1, &result, 1, vDSP_Length(deviation.count))
            return result
        }
    }
}
