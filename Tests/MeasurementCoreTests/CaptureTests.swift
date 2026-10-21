import CoreVideo
import Foundation
import Testing
@testable import MeasurementCore

@Suite("FrameSequence")
struct FrameSequenceTests {

    @Test("Sequence exposes frames and matching metadata")
    func countsMatch() {
        let sequence = SampleData.frameSequence(frameCount: 6)
        #expect(sequence.count == 6)
        #expect(sequence.metadata.frames.count == 6)
        for index in 0..<sequence.count {
            #expect(sequence.metadata.frames[index].index == index)
        }
    }

    @Test("Plane access yields the luma plane with a usable stride")
    func lumaPlaneAccess() throws {
        let dimensions = FrameDimensions(width: 64, height: 48)
        let sequence = SampleData.frameSequence(frameCount: 2, dimensions: dimensions)
        try sequence.withPlane(at: 0) { plane in
            #expect(plane.width == 64)
            #expect(plane.height == 48)
            #expect(plane.bytesPerRow >= 64)   // padded, hence >= not ==
            #expect(plane.planeIndex == 0)
            #expect(plane.rowBytes(0).count == plane.bytesPerRow)
            #expect(plane.byteCount == plane.bytesPerRow * 48)
        }
    }

    @Test("forEachPlane visits every frame in order")
    func iterationOrder() throws {
        let sequence = SampleData.frameSequence(frameCount: 5)
        var visited: [Int] = []
        try sequence.forEachPlane { index, _, metadata in
            visited.append(index)
            #expect(metadata.index == index)
        }
        #expect(visited == [0, 1, 2, 3, 4])
    }

    @Test("releaseFrames marks the sequence released")
    func release() {
        let sequence = SampleData.frameSequence(frameCount: 2)
        #expect(!sequence.isReleased)
        sequence.releaseFrames()
        #expect(sequence.isReleased)
    }
}

@Suite("FrameSequenceBuilder")
struct FrameSequenceBuilderTests {

    private func makeBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        )
        return buffer!
    }

    @Test("Builder assigns sequential indices so metadata cannot desync from buffers")
    func indicesAreAssigned() {
        let builder = FrameSequenceBuilder(maximumFrameCount: 10)
        for i in 0..<4 {
            _ = builder.append(
                pixelBuffer: makeBuffer(),
                presentationTime: Double(i) / 120.0,
                exposureDuration: 1.0 / 2000.0,
                iso: 400,
                exposureMode: .manual
            )
        }
        let sequence = builder.finalize(
            dimensions: FrameDimensions(width: 16, height: 16),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nominalFrameRate: 120,
            lineReadoutTime: 18.5e-6,
            deviceCapability: SampleData.tier1Capability,
            startedAt: SampleData.now
        )
        #expect(sequence.count == 4)
        #expect(sequence.metadata.frames.map(\.index) == [0, 1, 2, 3])
    }

    @Test("Builder refuses frames past its ceiling instead of growing")
    func ceilingIsEnforced() {
        let builder = FrameSequenceBuilder(maximumFrameCount: 2)
        #expect(builder.append(pixelBuffer: makeBuffer(), presentationTime: 0, exposureDuration: 0.001, iso: 100, exposureMode: .manual) == .accepted(count: 1))
        #expect(builder.append(pixelBuffer: makeBuffer(), presentationTime: 0.01, exposureDuration: 0.001, iso: 100, exposureMode: .manual) == .accepted(count: 2))
        #expect(builder.append(pixelBuffer: makeBuffer(), presentationTime: 0.02, exposureDuration: 0.001, iso: 100, exposureMode: .manual) == .full)
        #expect(builder.count == 2)
    }

    @Test("finalize empties the builder so a second call cannot duplicate frames")
    func finalizeResets() {
        let builder = FrameSequenceBuilder(maximumFrameCount: 4)
        _ = builder.append(pixelBuffer: makeBuffer(), presentationTime: 0, exposureDuration: 0.001, iso: 100, exposureMode: .manual)
        _ = builder.finalize(
            dimensions: FrameDimensions(width: 16, height: 16),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nominalFrameRate: 120, lineReadoutTime: nil,
            deviceCapability: SampleData.tier3Capability, startedAt: SampleData.now
        )
        #expect(builder.count == 0)
    }
}

@Suite("CaptureMetadata")
struct CaptureMetadataTests {

    @Test("Line count is the buffer height")
    func lineCountIsHeight() {
        let rows = SampleData.captureMetadata(dimensions: FrameDimensions(width: 1920, height: 1080))
        #expect(rows.lineCount == 1080)
    }

    @Test("Stable exposure detects a mid-capture change")
    func exposureStability() {
        let stable = SampleData.captureMetadata(frameCount: 10)
        #expect(stable.hasStableExposure)

        var frames = stable.frames
        frames[5] = FrameMetadata(
            index: 5,
            presentationTime: frames[5].presentationTime,
            exposureDuration: 1.0 / 500.0,   // device changed its mind
            iso: 800,
            exposureMode: .automatic
        )
        let drifting = CaptureMetadata(
            dimensions: stable.dimensions,
            pixelFormat: stable.pixelFormat,
            nominalFrameRate: stable.nominalFrameRate,
            frames: frames,
            lineReadoutTime: stable.lineReadoutTime,
            deviceCapability: stable.deviceCapability,
            startedAt: stable.startedAt
        )
        #expect(!drifting.hasStableExposure)
    }

    @Test("Duration comes from frame timestamps, not wall clock")
    func duration() {
        let metadata = SampleData.captureMetadata(frameCount: 121, frameRate: 120)
        #expect(abs(metadata.duration - 1.0) < 1e-9)
    }

    @Test("Metadata round-trips through Codable so captures can be replayed")
    func codableRoundTrip() throws {
        let original = SampleData.captureMetadata(frameCount: 12)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureMetadata.self, from: data)
        #expect(decoded == original)
    }
}
