import CoreVideo
import Foundation

/// Row means only: `rowBrightness[y]` was read out at `presentationTime + y * lineReadoutTime`.
public struct RowBrightnessFrame: Sendable {
    public let rowBrightness: [Float]
    public let presentationTime: TimeInterval
    public let exposureDuration: TimeInterval
    public let iso: Float
    public let exposureMode: ExposureMode
}

public struct RowBrightnessCapture: Sendable {
    public let frames: [RowBrightnessFrame]
    public let lineReadoutTime: TimeInterval?

    /// At or above 250/255; high values mean amplitude would read falsely low.
    public let saturatedFraction: Double

    /// At or below 3/255.
    public let crushedFraction: Double
    public let meanBrightness: Float
}

public enum RowBrightnessExtractor {

    /// - Throws: `unsupportedPixelFormat` for anything but 8-bit biplanar 4:2:0.
    public static func extract(from frames: FrameSequence) throws -> RowBrightnessCapture {
        var rowFrames: [RowBrightnessFrame] = []
        rowFrames.reserveCapacity(frames.count)

        var saturatedCount = 0
        var crushedCount = 0
        var totalRows = 0
        var brightnessSum: Double = 0

        try frames.forEachPlane(plane: 0) { _, plane, metadata in
            try Task.checkCancellation()

            guard plane.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || plane.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            else {
                throw AnalysisError.unsupportedPixelFormat(plane.pixelFormat)
            }

            let nominalBlackPoint = nominalBlackPointCode(for: plane.pixelFormat)

            var rowMeans = [Float](repeating: 0, count: plane.height)
            for y in 0..<plane.height {
                let bytes = plane.rowBytes(y)
                var sum: UInt64 = 0
                for x in 0..<plane.width {
                    sum += UInt64(bytes[x])
                }
                let mean = Float(sum) / Float(plane.width)
                // Health checks read the raw sensor code, not the corrected value.
                if mean >= 250 { saturatedCount += 1 }
                if mean <= 3 { crushedCount += 1 }
                brightnessSum += Double(mean)
                totalRows += 1

                // Not clamped at zero: clamping would be its own silent nonlinearity.
                rowMeans[y] = mean - nominalBlackPoint
            }

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

        return RowBrightnessCapture(
            frames: rowFrames,
            lineReadoutTime: frames.metadata.lineReadoutTime,
            saturatedFraction: totalRows > 0 ? Double(saturatedCount) / Double(totalRows) : 0,
            crushedFraction: totalRows > 0 ? Double(crushedCount) / Double(totalRows) : 0,
            meanBrightness: totalRows > 0 ? Float(brightnessSum / Double(totalRows)) : 0
        )
    }

    static func nominalBlackPointCode(for pixelFormat: UInt32) -> Float {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
    }
}
