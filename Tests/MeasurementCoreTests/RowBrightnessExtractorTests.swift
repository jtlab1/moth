import CoreVideo
import Foundation
import Testing
@testable import MeasurementCore

@Suite("RowBrightnessExtractor black point")
struct RowBrightnessExtractorTests {

    private static func uniformBuffer(width: Int, height: Int, lumaValue: UInt8, pixelFormat: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                luma[row * stride + column] = lumaValue
            }
        }
        return pixelBuffer
    }

    private static func sequence(
        lumaValue: UInt8,
        width: Int = 8,
        height: Int = 4,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) -> FrameSequence {
        let buffer = uniformBuffer(width: width, height: height, lumaValue: lumaValue, pixelFormat: pixelFormat)
        let base = SampleData.captureMetadata(
            frameCount: 1,
            dimensions: FrameDimensions(width: width, height: height)
        )
        let metadata = CaptureMetadata(
            dimensions: base.dimensions,
            pixelFormat: pixelFormat,
            nominalFrameRate: base.nominalFrameRate,
            frames: base.frames,
            lineReadoutTime: base.lineReadoutTime,
            deviceCapability: base.deviceCapability,
            startedAt: base.startedAt
        )
        return FrameSequence(buffers: [buffer], metadata: metadata)
    }

    @Test("Video-range format subtracts the nominal 16-code black point")
    func nominalBlackPointFallbackVideoRange() throws {
        let sequence = Self.sequence(lumaValue: 20, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let extracted = try RowBrightnessExtractor.extract(from: sequence)
        for value in extracted.frames[0].rowBrightness {
            #expect(abs(value - 4) < 0.001)   // 20 - 16
        }
    }

    @Test("Full-range format has no nominal black point to subtract")
    func nominalBlackPointFallbackFullRange() throws {
        let sequence = Self.sequence(lumaValue: 20, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let extracted = try RowBrightnessExtractor.extract(from: sequence)
        for value in extracted.frames[0].rowBrightness {
            #expect(abs(value - 20) < 0.001)
        }
    }

    @Test("Subtraction is never clamped at zero")
    func negativeValuesSurvive() throws {
        let sequence = Self.sequence(
            lumaValue: 10, height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let extracted = try RowBrightnessExtractor.extract(from: sequence)
        for value in extracted.frames[0].rowBrightness {
            #expect(abs(value - (-6)) < 0.001)   // 10 - 16
        }
    }

    @Test("Saturation and crush detection read the raw sensor code, not the corrected value")
    func saturationAndCrushUseRawCode() throws {
        let saturated = Self.sequence(
            lumaValue: 255, height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let extractedSaturated = try RowBrightnessExtractor.extract(from: saturated)
        #expect(extractedSaturated.saturatedFraction == 1)

        // Crush is judged on the raw code, so video-range black (16) must not read as crushed.
        let atNominalBlack = Self.sequence(
            lumaValue: 16, height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let extractedBlack = try RowBrightnessExtractor.extract(from: atNominalBlack)
        #expect(extractedBlack.crushedFraction == 0)
    }
}
