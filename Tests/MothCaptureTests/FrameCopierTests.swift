import CoreVideo
import Foundation
import Testing
@testable import MeasurementCore
@testable import MothCapture

/// A shearing copy produces a smooth periodic gradient: a convincing, fabricated measurement.
@Suite("FrameCopier")
struct FrameCopierTests {

    static let sourceWidth = 64
    static let sourceHeight = 48

    /// A function of both row and col, so shear and origin errors both show up.
    static func makeSource(width: Int = sourceWidth, height: Int = sourceHeight) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                luma[row * lumaStride + column] = UInt8((row &* 7 &+ column) & 0xFF)
            }
        }

        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        for row in 0..<chromaHeight {
            for byte in 0..<(chromaWidth * 2) {
                chroma[row * chromaStride + byte] = UInt8((row &* 11 &+ byte &* 3) & 0xFF)
            }
        }
        return pixelBuffer
    }

    static func luma(_ buffer: CVPixelBuffer, row: Int, column: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + column]
    }

    static func chroma(_ buffer: CVPixelBuffer, row: Int, byte: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        return base[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + byte]
    }

    // MARK: - Column strip

    @Test("A column strip keeps every row and copies luma without shear")
    func columnStripLuma() throws {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .columnStrip(width: 16))
        let destination = try #require(copier.retain(source))
        let origin = ((Self.sourceWidth - 16) / 2) & ~1

        #expect(CVPixelBufferGetWidth(destination) == 16)
        #expect(CVPixelBufferGetHeight(destination) == Self.sourceHeight)
        #expect(copier.region?.originY == 0)
        #expect(copier.region?.originX == origin)

        for row in 0..<Self.sourceHeight {
            for column in 0..<16 {
                let expected = UInt8((row &* 7 &+ (origin + column)) & 0xFF)
                #expect(Self.luma(destination, row: row, column: column) == expected)
            }
        }
    }

    @Test("The chroma plane stays aligned with the luma plane")
    func columnStripChroma() throws {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .columnStrip(width: 16))
        let destination = try #require(copier.retain(source))
        let origin = ((Self.sourceWidth - 16) / 2) & ~1

        let height = CVPixelBufferGetHeightOfPlane(destination, 1)
        let width = CVPixelBufferGetWidthOfPlane(destination, 1)
        for row in 0..<height {
            for byte in 0..<(width * 2) {
                let sourceByte = (origin / 2) * 2 + byte
                let expected = UInt8((row &* 11 &+ sourceByte &* 3) & 0xFF)
                #expect(Self.chroma(destination, row: row, byte: byte) == expected)
            }
        }
    }

    @Test("An odd strip width is rounded even so 4:2:0 chroma stays in step")
    func oddWidthIsRounded() {
        let copier = FrameCopier(policy: .columnStrip(width: 15))
        _ = copier.retain(Self.makeSource())
        #expect(copier.retainedDimensions?.width == 14)
        #expect((copier.region?.originX ?? 1) % 2 == 0)
    }

    @Test("A strip wider than the frame clamps instead of reading out of bounds")
    func oversizedWidthClamps() {
        let copier = FrameCopier(policy: .columnStrip(width: 4096))
        _ = copier.retain(Self.makeSource())
        #expect(copier.retainedDimensions?.width == Self.sourceWidth)
        #expect(copier.region?.originX == 0)
    }

    // MARK: - Other policies

    @Test("Full-frame retention copies every pixel and does not alias the source")
    func fullFrame() throws {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .fullFrame)
        let destination = try #require(copier.retain(source))

        #expect(destination !== source)
        #expect(CVPixelBufferGetWidth(destination) == Self.sourceWidth)
        #expect(CVPixelBufferGetHeight(destination) == Self.sourceHeight)
        for row in 0..<Self.sourceHeight {
            for column in 0..<Self.sourceWidth {
                #expect(Self.luma(destination, row: row, column: column) == UInt8((row &* 7 &+ column) & 0xFF))
            }
        }
    }

    @Test("Retaining the original hands back the same buffer with no crop region")
    func retainOriginal() {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .retainOriginal)
        #expect(copier.retain(source) === source)
        #expect(copier.region == nil)
        #expect(copier.retainedDimensions == FrameDimensions(width: Self.sourceWidth, height: Self.sourceHeight))
    }

    // MARK: - Pool behaviour

    @Test("The pool issues a distinct buffer for every frame held at once")
    func poolIssuesDistinctBuffers() {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .columnStrip(width: 16))
        // Held on purpose: a pool recycles a released buffer, which would prove nothing.
        var held: [CVPixelBuffer] = []
        for _ in 0..<40 {
            if let buffer = copier.retain(source) { held.append(buffer) }
        }
        #expect(held.count == 40)
        #expect(Set(held.map(ObjectIdentifier.init)).count == 40)
    }

    @Test("Reset clears the retained shape so the next capture starts clean")
    func reset() {
        let copier = FrameCopier(policy: .columnStrip(width: 16))
        _ = copier.retain(Self.makeSource())
        copier.reset()
        #expect(copier.retainedDimensions == nil)
        #expect(copier.region == nil)
    }

    // MARK: - Into a FrameSequence

    @Test("The crop region survives into the metadata analysis receives")
    func regionReachesMetadata() throws {
        let source = Self.makeSource()
        let copier = FrameCopier(policy: .columnStrip(width: 16))
        let builder = FrameSequenceBuilder(maximumFrameCount: 8)
        for index in 0..<5 {
            let buffer = try #require(copier.retain(source))
            _ = builder.append(
                pixelBuffer: buffer,
                presentationTime: Double(index) / 120,
                exposureDuration: 1.0 / 2000,
                iso: 400,
                exposureMode: .manual
            )
        }
        let sequence = builder.finalize(
            dimensions: try #require(copier.retainedDimensions),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nominalFrameRate: 120,
            region: copier.region,
            lineReadoutTime: 18.5e-6,
            deviceCapability: SampleData.tier1Capability,
            startedAt: SampleData.now
        )

        #expect(sequence.count == 5)
        #expect(sequence.metadata.region?.originX == 24)
        #expect(sequence.metadata.region?.originY == 0)
        #expect(sequence.metadata.dimensions.width == 16)
        #expect(sequence.metadata.lineCount == Self.sourceHeight)

        try sequence.withPlane(at: 0) { plane in
            #expect(plane.height == Self.sourceHeight)
            #expect(plane.width == 16)
        }
        sequence.releaseFrames()
    }
}

@Suite("CaptureProgress")
struct CaptureProgressTests {

    @Test("Fraction tracks elapsed time and clamps at both ends")
    func fraction() {
        #expect(CaptureProgress(framesCaptured: 0, elapsed: 0, duration: 4).fraction == 0)
        #expect(CaptureProgress(framesCaptured: 10, elapsed: 2, duration: 4).fraction == 0.5)
        #expect(CaptureProgress(framesCaptured: 10, elapsed: 9, duration: 4).fraction == 1)
    }

    @Test("A zero duration cannot divide by zero")
    func zeroDuration() {
        #expect(CaptureProgress(framesCaptured: 0, elapsed: 1, duration: 0).fraction == 0)
    }
}
