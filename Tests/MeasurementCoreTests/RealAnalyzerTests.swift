import CoreVideo
import Foundation
import Testing
@testable import MeasurementCore

/// Real controlled content, unlike `SampleData`'s blank buffers.
enum SyntheticSignal {

    /// `rowTimeStep` is the true spacing; `metadataLineReadoutTime` is what the capture
    /// claims, `nil` to simulate an uncalibrated device.
    static func capture(
        frameCount: Int,
        height: Int = 1080,
        width: Int = 32,
        frameRate: Double = 120,
        rowTimeStep: TimeInterval,
        metadataLineReadoutTime: TimeInterval?,
        exposureMode: ExposureMode = .manual,
        deviceCapability: DeviceCapabilityProfile,
        linearIntensity: (TimeInterval) -> Double
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
            guard let pixelBuffer = buffer else {
                fatalError("failed to create synthetic pixel buffer")
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
                .assumingMemoryBound(to: UInt8.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for row in 0..<height {
                let t = frameStart + Double(row) * rowTimeStep
                let linear = max(0, min(1, linearIntensity(t)))
                let code = gammaEncode(linear)
                let value = UInt8(max(0, min(255, (code * 255).rounded())))
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
                    exposureMode: exposureMode
                )
            )
        }

        let metadata = CaptureMetadata(
            dimensions: FrameDimensions(width: width, height: height),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nominalFrameRate: frameRate,
            frames: frames,
            lineReadoutTime: metadataLineReadoutTime,
            deviceCapability: deviceCapability,
            startedAt: SampleData.now
        )
        return FrameSequence(buffers: buffers, metadata: metadata)
    }

    static func gammaEncode(_ linear: Double) -> Double {
        let clamped = max(0, min(1, linear))
        if clamped <= 0.018 {
            return 4.5 * clamped
        }
        return 1.099 * pow(clamped, 0.45) - 0.099
    }

    static let tier1Capability = DeviceCapabilityProfile(
        modelIdentifier: "iPhone17,1",
        supportsManualExposure: true,
        exposureDurationRange: 1.0 / 8000...1.0 / 3,
        isoRange: 34...3072,
        maximumFrameRate: 240,
        providesLinearCapture: true,
        isCalibrated: true
    )

    static let tier3Capability = DeviceCapabilityProfile(
        modelIdentifier: "iPhone12,1",
        supportsManualExposure: true,
        exposureDurationRange: 1.0 / 8000...1.0 / 3,
        isoRange: 32...2016,
        maximumFrameRate: 120,
        providesLinearCapture: false,
        isCalibrated: false
    )

}

@Suite("Real flicker analyzer")
struct RealFlickerAnalyzerTests {

    private static let tier1Capability = SyntheticSignal.tier1Capability
    private static let tier3Capability = SyntheticSignal.tier3Capability
    private static let lineReadoutTime: TimeInterval = 18.5e-6

    @Test("Recovers a known sinusoidal frequency and modulation depth at Tier 1")
    func recoversFrequencyAndDepth() async throws {
        let frequencyHz = 100.0
        let midpoint = 0.5
        let targetDepthPercent = 20.0
        let amplitude = midpoint * targetDepthPercent / 100.0

        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: Self.lineReadoutTime,
            deviceCapability: Self.tier1Capability
        ) { t in midpoint + amplitude * sin(2 * .pi * frequencyHz * t) }
        defer { sequence.releaseFrames() }

        let result = try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)

        #expect(result.tier == .tier1)
        #expect(result.presence == .present)
        let hz = try #require(result.frequencyHz)
        #expect(abs(hz - frequencyHz) < 10)
        let depth = try #require(result.modulationDepthPercent)
        #expect(abs(depth - targetDepthPercent) < 6)
        #expect(result.verdict == IEEE1789.classify(frequencyHz: hz, modulationDepthPercent: depth))
    }

    @Test("Tier 3 without calibration reports presence, not a frequency")
    func tier3PresenceOnly() async throws {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: nil,
            deviceCapability: Self.tier3Capability
        ) { t in 0.5 + 0.2 * sin(2 * .pi * 100 * t) }
        defer { sequence.releaseFrames() }

        let result = try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        #expect(result.tier == .tier3)
        #expect(result.presence == .present)
        #expect(result.frequencyHz == nil)
        #expect(result.modulationDepthPercent == nil)
        #expect(result.verdict == nil)
    }

    @Test("A flat, non-flickering capture reads as absent rather than throwing")
    func absentForFlatSignal() async throws {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: nil,
            deviceCapability: Self.tier3Capability
        ) { _ in 0.5 }
        defer { sequence.releaseFrames() }

        let result = try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        #expect(result.presence == .absent)
        #expect(result.frequencyHz == nil)
    }

    @Test("A very dark capture throws insufficientSignal rather than guessing")
    func darkCaptureThrows() async {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: Self.lineReadoutTime,
            deviceCapability: Self.tier1Capability
        ) { _ in 0.0 }
        defer { sequence.releaseFrames() }

        await #expect(throws: AnalysisError.self) {
            try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        }
    }

    @Test("Heavy clipping throws sensorSaturated rather than a falsely-low depth")
    func clippingThrowsSaturated() async {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: Self.lineReadoutTime,
            deviceCapability: Self.tier1Capability
        ) { t in 0.5 + 0.8 * sin(2 * .pi * 100 * t) }
        defer { sequence.releaseFrames() }

        await #expect(throws: AnalysisError.self) {
            try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        }
    }

    @Test("Auto exposure caps the result below Tier 1 even on Tier-1-capable hardware")
    func autoExposureCapsTier() async throws {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: Self.lineReadoutTime,
            exposureMode: .automatic,
            deviceCapability: Self.tier1Capability
        ) { t in 0.5 + 0.1 * sin(2 * .pi * 100 * t) }
        defer { sequence.releaseFrames() }

        let result = try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        #expect(result.tier == .tier2)
        #expect(result.modulationDepthPercent == nil)
        #expect(result.verdict == nil)
        #expect(result.frequencyHz != nil)
    }

    @Test("Too few frames throws rather than analysing a meaningless capture")
    func tooFewFramesThrows() async {
        let sequence = SyntheticSignal.capture(
            frameCount: 2,
            rowTimeStep: Self.lineReadoutTime,
            metadataLineReadoutTime: Self.lineReadoutTime,
            deviceCapability: Self.tier1Capability
        ) { t in 0.5 + 0.2 * sin(2 * .pi * 100 * t) }
        defer { sequence.releaseFrames() }

        await #expect(throws: AnalysisError.self) {
            try await RealFlickerAnalyzer().analyze(frames: sequence, metadata: sequence.metadata)
        }
    }
}

@Suite("Periodogram diagnostics")
struct PeriodogramDiagnosticTests {
    @Test("Finds a known normalized frequency in a pure sine row signal")
    func findsKnownFrequency() throws {
        let sampleCount = 1080
        let trueNormalizedFreq = 100.0 * 18.5e-6
        var signal = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            signal[i] = Float(0.5 + 0.2 * sin(2 * .pi * trueNormalizedFreq * Double(i)))
        }
        let rowSignals = Array(repeating: signal, count: 20)
        let coarse = try #require(try Periodogram.coarsePeak(rowSignals: rowSignals))
        #expect(abs(coarse.normalizedFrequency - trueNormalizedFreq) < trueNormalizedFreq * 0.1)
    }
}

@Suite("Real device calibrator")
struct RealDeviceCalibratorTests {

    @Test("Solves a line readout time close to the true value used to generate the signal")
    func solvesKnownReadoutTime() async throws {
        let trueLineReadoutTime: TimeInterval = 20e-6
        let referenceFrequencyHz = 120.0

        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: trueLineReadoutTime,
            metadataLineReadoutTime: nil,
            deviceCapability: SyntheticSignal.tier1Capability
        ) { t in 0.5 + 0.3 * sin(2 * .pi * referenceFrequencyHz * t) }
        defer { sequence.releaseFrames() }

        let solved = try await RealDeviceCalibrator().solveLineReadoutTime(
            from: sequence, knownFrequencyHz: referenceFrequencyHz
        )

        #expect(DeviceCalibration.isPlausible(solved))
        #expect(abs(solved - trueLineReadoutTime) / trueLineReadoutTime < 0.2)
    }

    @Test("A capture with no usable signal throws rather than solving a bogus value")
    func noSignalThrows() async {
        let sequence = SyntheticSignal.capture(
            frameCount: 131,
            rowTimeStep: 20e-6,
            metadataLineReadoutTime: nil,
            deviceCapability: SyntheticSignal.tier1Capability
        ) { _ in 0.5 }
        defer { sequence.releaseFrames() }

        await #expect(throws: AnalysisError.self) {
            try await RealDeviceCalibrator().solveLineReadoutTime(from: sequence, knownFrequencyHz: 120)
        }
    }
}

