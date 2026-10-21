import CoreVideo
import Foundation
import Testing
@testable import MeasurementCore
@testable import MothCapture

#if DEBUG
/// The loader must be provably faithful on a known signal before a real-device dump can be
/// trusted as a regression fixture.
@Suite("DebugFrameDump round-trip")
struct DebugFrameDumpTests {

    /// Duplicates `SyntheticSignal`, which lives in another test target and isn't visible here.
    private static func syntheticCapture(
        frameCount: Int,
        height: Int,
        width: Int,
        frameRate: Double,
        rowTimeStep: TimeInterval,
        frequencyHz: Double,
        midpoint: Double,
        amplitude: Double
    ) -> FrameSequence {
        var buffers: [CVPixelBuffer] = []
        var frames: [FrameMetadata] = []

        for frameIndex in 0..<frameCount {
            let frameStart = Double(frameIndex) / frameRate
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer
            )
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for row in 0..<height {
                let t = frameStart + Double(row) * rowTimeStep
                let linear = midpoint + amplitude * sin(2 * Double.pi * frequencyHz * t)
                let value = UInt8(max(0, min(255, (linear * 255).rounded())))
                let rowPtr = lumaBase.advanced(by: row * lumaStride)
                for col in 0..<width { rowPtr[col] = value }
            }
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            memset(chromaBase, 128, chromaStride * chromaHeight)
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            buffers.append(pixelBuffer)
            frames.append(
                FrameMetadata(
                    index: frameIndex,
                    presentationTime: frameStart,
                    exposureDuration: 1.0 / 2000.0,
                    iso: 100,
                    exposureMode: .manual
                )
            )
        }

        let metadata = CaptureMetadata(
            dimensions: FrameDimensions(width: width, height: height),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nominalFrameRate: frameRate,
            frames: frames,
            lineReadoutTime: rowTimeStep,
            deviceCapability: DeviceCapabilityProfile(
                modelIdentifier: "iPhone17,1",
                supportsManualExposure: true,
                exposureDurationRange: 1.0 / 8000...1.0 / 3,
                isoRange: 34...3072,
                maximumFrameRate: 240,
                providesLinearCapture: true,
                isCalibrated: true
            ),
            startedAt: Date()
        )
        return FrameSequence(buffers: buffers, metadata: metadata)
    }

    private static func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MothDumpTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A dumped-and-reloaded capture analyses identically to the original")
    func roundTripPreservesAnalysis() async throws {
        let original = Self.syntheticCapture(
            frameCount: 131, height: 1080, width: 32, frameRate: 120,
            rowTimeStep: 18.5e-6, frequencyHz: 100, midpoint: 0.5, amplitude: 0.1
        )
        let originalResult = try await RealFlickerAnalyzer().analyze(frames: original, metadata: original.metadata)

        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let dumpURL = try DebugFrameDump.write(original, name: "round-trip", to: tempDirectory)
        #expect(FileManager.default.fileExists(atPath: dumpURL.appendingPathComponent("luma.bin").path))
        #expect(FileManager.default.fileExists(atPath: dumpURL.appendingPathComponent("metadata.json").path))

        let reloaded = try DebugFrameDump.load(name: "round-trip", from: tempDirectory)
        #expect(reloaded.count == original.count)

        let reloadedResult = try await RealFlickerAnalyzer().analyze(frames: reloaded, metadata: reloaded.metadata)

        #expect(originalResult.presence == reloadedResult.presence)
        #expect(originalResult.verdict == reloadedResult.verdict)
        #expect(originalResult.tier == reloadedResult.tier)

        let originalFrequency = try #require(originalResult.frequencyHz)
        let reloadedFrequency = try #require(reloadedResult.frequencyHz)
        #expect(abs(originalFrequency - reloadedFrequency) < 0.01)

        let originalDepth = try #require(originalResult.modulationDepthPercent)
        let reloadedDepth = try #require(reloadedResult.modulationDepthPercent)
        #expect(abs(originalDepth - reloadedDepth) < 0.01)
    }

    @Test("Loading a dump with a corrupted luma byte count throws rather than misreading frames")
    func loadDetectsCorruptDump() throws {
        let tempDirectory = Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let metadata = CaptureMetadata(
            dimensions: FrameDimensions(width: 4, height: 4),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nominalFrameRate: 30,
            frames: [
                FrameMetadata(index: 0, presentationTime: 0, exposureDuration: 0.01, iso: 100, exposureMode: .manual)
            ],
            lineReadoutTime: 18.5e-6,
            deviceCapability: DeviceCapabilityProfile(
                modelIdentifier: "iPhone17,1", supportsManualExposure: true,
                exposureDurationRange: 1.0 / 8000...1.0 / 3, isoRange: 34...3072,
                maximumFrameRate: 240, providesLinearCapture: true, isCalibrated: true
            ),
            startedAt: Date()
        )
        try JSONEncoder().encode(metadata).write(to: tempDirectory.appendingPathComponent("metadata.json"))
        // 4x4 frame needs 16 luma bytes; only 3 are written.
        try Data([0, 1, 2]).write(to: tempDirectory.appendingPathComponent("luma.bin"))

        #expect(throws: DebugFrameDump.DumpError.self) {
            try DebugFrameDump.load(name: "corrupt", from: tempDirectory)
        }
    }
}
#endif
