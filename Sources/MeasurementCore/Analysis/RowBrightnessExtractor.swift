import Accelerate
import CoreVideo
import Foundation

/// Row means only: `rowBrightness[y]` was read out at `presentationTime + y * lineReadoutTime`.
public struct RowBrightnessFrame: Sendable {
    /// Relative linear exposure when the capture `isLinear`, else black-subtracted code units.
    public let rowBrightness: [Float]
    public let presentationTime: TimeInterval
    public let exposureDuration: TimeInterval
    public let iso: Float
    public let exposureMode: ExposureMode
}

public struct RowBrightnessCapture: Sendable {
    public let frames: [RowBrightnessFrame]
    public let lineReadoutTime: TimeInterval?

    /// True if every pixel went through a `ResponseCurve` before averaging.
    /// False means rows are black-subtracted codes, fine for frequency but not depth.
    public let isLinear: Bool

    /// Code subtracted from rows when not linear; the raw code of nominal black either way.
    public let blackPointCode: Float

    /// Each row's mean raw code over time, so the flat field can spot crushed rows in camera units.
    public let rowMeanCodes: [Float]

    /// Rows where too many pixels hit the saturation code in any frame.
    /// Clipped pixels make the mean read low, so these rows get excluded, not corrected.
    public let rowSaturated: [Bool]

    /// Rows where too many pixels sat at black during their brighter frames.
    /// Clipped noise flattens the flicker, so these get excluded too (dark-end version of `rowSaturated`).
    public let rowBlackClipped: [Bool]

    /// Row means at or above 250/255; high values mean amplitude would read falsely low.
    public let saturatedFraction: Double

    /// Row means at or below 3/255.
    public let crushedFraction: Double

    /// Raw code.
    public let meanBrightness: Float

    public var rowCount: Int { rowMeanCodes.count }
}

public enum RowBrightnessExtractor {

    /// Linearises through the capture's own `metadata.responseCurve`, if it has one.
    public static func extract(from frames: FrameSequence) throws -> RowBrightnessCapture {
        try extract(from: frames, response: frames.metadata.responseCurve)
    }

    /// With `response`, pixels get linearized before averaging, since the mean of codes isn't the code of the mean.
    /// Without it rows stay in black-subtracted codes. Throws for anything but 8-bit 4:2:0.
    public static func extract(from frames: FrameSequence, response: ResponseCurve?) throws -> RowBrightnessCapture {
        var rowFrames: [RowBrightnessFrame] = []
        rowFrames.reserveCapacity(frames.count)

        var saturatedCount = 0
        var crushedCount = 0
        var totalRows = 0
        var brightnessSum: Double = 0
        var blackPoint: Float = 0
        var rowCodeSums: [Double] = []
        var rowSaturated: [Bool] = []
        var frameCount = 0

        // Scratch reused across rows; vDSP keeps this fast in Debug builds too.
        var scratchCapacity = 0
        var codes = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        var linear = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        defer {
            codes.deallocate()
            linear.deallocate()
        }
        let table = response?.values ?? []

        // The clip floor: nominal black, or a slightly higher pedestal if the first frame bottoms out there.
        var floorCode = Float(0)
        if !frames.isEmpty {
            floorCode = try frames.withPlane(at: 0) { plane in
                let black = nominalBlackPointCode(for: plane.pixelFormat)
                var lowest = UInt8.max
                for y in 0..<plane.height {
                    let row = plane.rowBytes(y)
                    for x in 0..<min(plane.width, row.count) where row[x] < lowest { lowest = row[x] }
                }
                let lowestCode = Float(lowest)
                return lowestCode <= black + Self.maximumPedestalCodes ? lowestCode : black
            }
        }
        var frameRowCodes: [[Float]] = []
        var frameBlackCounts: [[Int32]] = []

        try frames.forEachPlane(plane: 0) { _, plane, metadata in
            try Task.checkCancellation()

            guard plane.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || plane.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            else {
                throw AnalysisError.unsupportedPixelFormat(plane.pixelFormat)
            }

            blackPoint = nominalBlackPointCode(for: plane.pixelFormat)
            let width = plane.width
            if width > scratchCapacity {
                codes.deallocate()
                linear.deallocate()
                codes = .allocate(capacity: width)
                linear = .allocate(capacity: width)
                scratchCapacity = width
            }
            if rowCodeSums.count != plane.height {
                // A mid-capture size change would misalign every row; only the first size counts.
                guard rowCodeSums.isEmpty else { return }
                rowCodeSums = [Double](repeating: 0, count: plane.height)
                rowSaturated = [Bool](repeating: false, count: plane.height)
            }
            let saturatedPixelLimit = Int(CaptureStandard.saturatedRowPixelFraction * Double(width))
            var low: Float = floorCode + 0.5
            var blackCounts = [Int32](repeating: 0, count: plane.height)
            var rowCodes = [Float](repeating: 0, count: plane.height)
            // Video range clips at 235, so its threshold sits the same distance below 235 as full range's does below 255.
            var high = Float(LumaCodeLevels(pixelFormat: plane.pixelFormat).saturation) - 0.5

            var rowMeans = [Float](repeating: 0, count: plane.height)
            for y in 0..<plane.height {
                let bytes = plane.rowBytes(y)
                let source = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                vDSP_vfltu8(source, 1, codes, 1, vDSP_Length(width))

                var mean: Float = 0
                vDSP_meanv(codes, 1, &mean, vDSP_Length(width))
                var belowCount: vDSP_Length = 0
                var aboveCount: vDSP_Length = 0
                vDSP_vclipc(codes, 1, &low, &high, linear, 1, vDSP_Length(width), &belowCount, &aboveCount)
                if Int(aboveCount) > saturatedPixelLimit { rowSaturated[y] = true }
                blackCounts[y] = Int32(belowCount)
                rowCodes[y] = mean

                // Health checks read the raw sensor code, not the corrected value.
                if mean >= 250 { saturatedCount += 1 }
                if mean <= 3 { crushedCount += 1 }
                brightnessSum += Double(mean)
                rowCodeSums[y] += Double(mean)
                totalRows += 1

                if table.isEmpty {
                    // Not clamped at zero: clamping would be its own silent nonlinearity.
                    rowMeans[y] = mean - blackPoint
                } else {
                    var linearMean: Float = 0
                    table.withUnsafeBufferPointer { lut in
                        vDSP_vindex(lut.baseAddress!, codes, 1, linear, 1, vDSP_Length(width))
                    }
                    vDSP_meanv(linear, 1, &linearMean, vDSP_Length(width))
                    rowMeans[y] = linearMean
                }
            }
            frameCount += 1
            frameRowCodes.append(rowCodes)
            frameBlackCounts.append(blackCounts)

            rowFrames.append(
                RowBrightnessFrame(
                    rowBrightness: rowMeans,
                    presentationTime: metadata.presentationTime,
                    exposureDuration: metadata.exposureDuration,
                    iso: metadata.iso,
                    exposureMode: metadata.exposureMode
                )
            )
        }

        let rowMeanCodes = rowCodeSums.map { frameCount > 0 ? Float($0 / Double(frameCount)) : 0 }
        let width = frames.isEmpty ? 0 : (frames.metadata.dimensions.width)
        var rowBlackClipped = [Bool](repeating: false, count: rowMeanCodes.count)
        for row in rowMeanCodes.indices where width > 0 {
            var clipped = 0
            var brightFrames = 0
            for frame in frameRowCodes.indices where frameRowCodes[frame][row] >= rowMeanCodes[row] {
                clipped += Int(frameBlackCounts[frame][row])
                brightFrames += 1
            }
            if brightFrames > 0 {
                rowBlackClipped[row] = Double(clipped) / Double(brightFrames * width) > Self.blackClippedPixelFraction
            }
        }
        return RowBrightnessCapture(
            frames: rowFrames,
            lineReadoutTime: frames.metadata.lineReadoutTime,
            isLinear: response != nil,
            blackPointCode: blackPoint,
            rowMeanCodes: rowMeanCodes,
            rowSaturated: rowSaturated,
            rowBlackClipped: rowBlackClipped,
            saturatedFraction: totalRows > 0 ? Double(saturatedCount) / Double(totalRows) : 0,
            crushedFraction: totalRows > 0 ? Double(crushedCount) / Double(totalRows) : 0,
            meanBrightness: totalRows > 0 ? Float(brightnessSum / Double(totalRows)) : 0
        )
    }

    /// Same 5% as saturation; at that point clipping lifts a row's mean by about 1%.
    public static let blackClippedPixelFraction: Double = 0.05

    /// If a frame's darkest pixel is this close to black, treat it as clipping at a pedestal.
    static let maximumPedestalCodes: Float = 8

    static func nominalBlackPointCode(for pixelFormat: UInt32) -> Float {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
    }
}
