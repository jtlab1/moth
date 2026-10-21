import CoreVideo
import Testing
@testable import MothCapture

/// The grid must span the whole frame, or a light outside it could go unnoticed.
@Suite("Live dim sampling")
struct LiveDimSamplingTests {

    private static func uniformBuffer(width: Int, height: Int, lumaValue: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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

    @Test("A uniform buffer samples to exactly its own luma value")
    func uniformBufferSamplesExactly() {
        let buffer = Self.uniformBuffer(width: 64, height: 48, lumaValue: 120)
        #expect(CameraCaptureController.sparseLumaSample(buffer) == 120)
    }

    @Test("A pure-black buffer samples to zero, matching the crushed threshold's own scale")
    func blackBufferSamplesToZero() {
        let buffer = Self.uniformBuffer(width: 64, height: 48, lumaValue: 0)
        #expect(CameraCaptureController.sparseLumaSample(buffer) == 0)
    }

    @Test("The grid spans the whole frame, not just one corner")
    func gridSpansWholeFrame() throws {
        // A one-corner sample would read fully bright or black; spanning lands between.
        var buffer: CVPixelBuffer?
        let width = 64, height = 48
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                let inBlackQuadrant = row < height / 2 && column < width / 2
                luma[row * stride + column] = inBlackQuadrant ? 0 : 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let sample = try #require(CameraCaptureController.sparseLumaSample(pixelBuffer))
        #expect(sample > 0)
        #expect(sample < 255)
    }

    @Test("A buffer smaller than the sample grid still returns a value rather than crashing")
    func tinyBufferDoesNotCrash() {
        let buffer = Self.uniformBuffer(width: 2, height: 2, lumaValue: 40)
        #expect(CameraCaptureController.sparseLumaSample(buffer) == 40)
    }
}
