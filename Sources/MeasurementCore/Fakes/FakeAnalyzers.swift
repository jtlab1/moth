#if DEBUG
import Foundation

// Hardcoded results that never look at the pixels: a fake that half-works invites trust.
// DEBUG-only and in the module because several test targets share it; it never ships.

public enum FlickerScenario: String, Sendable, CaseIterable {
    /// Fluorescent tube on a magnetic ballast.
    case tier1ExceedsLimit
    /// Cheap LED driver.
    case tier1LowRisk
    case tier1NoEffect
    case tier1NoFlicker
    case tier2FrequencyOnly
    case tier3PresentOnly
    case tier3AbsentOnly
    case tier1LowConfidence
    case failsInsufficientSignal
    case failsAmbiguous
    case failsSaturated
}

public struct FakeFlickerAnalyzer: FlickerAnalyzing {
    public let scenario: FlickerScenario

    /// Keeps the analysing state visible during development instead of flashing past.
    public let latency: Duration

    public init(scenario: FlickerScenario = .tier1ExceedsLimit, latency: Duration = .milliseconds(600)) {
        self.scenario = scenario
        self.latency = latency
    }

    public func analyze(frames: FrameSequence, metadata: CaptureMetadata) async throws -> FlickerResult {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        try Task.checkCancellation()
        return try Self.result(for: scenario)
    }

    /// Synchronous for previews, which can't await.
    public static func result(for scenario: FlickerScenario) throws -> FlickerResult {
        switch scenario {
        case .tier1ExceedsLimit:
            return FlickerResult(
                frequencyHz: 100,
                modulationDepthPercent: 42.8,
                verdict: .exceedsLowRisk,
                presence: .present,
                confidence: .high,
                tier: .tier1
            )
        case .tier1LowRisk:
            return FlickerResult(
                frequencyHz: 120,
                modulationDepthPercent: 6.4,
                verdict: .lowRisk,
                presence: .present,
                confidence: .high,
                tier: .tier1
            )
        case .tier1NoEffect:
            return FlickerResult(
                frequencyHz: 1_240,
                modulationDepthPercent: 2.1,
                verdict: .noObservableEffect,
                presence: .present,
                confidence: .high,
                tier: .tier1
            )
        case .tier1NoFlicker:
            return FlickerResult(
                presence: .absent,
                confidence: .high,
                tier: .tier1
            )
        case .tier2FrequencyOnly:
            return FlickerResult(
                frequencyHz: 100,
                presence: .present,
                confidence: .medium,
                tier: .tier2
            )
        case .tier3PresentOnly:
            return FlickerResult(
                presence: .present,
                confidence: .medium,
                tier: .tier3
            )
        case .tier3AbsentOnly:
            return FlickerResult(
                presence: .absent,
                confidence: .low,
                tier: .tier3
            )
        case .tier1LowConfidence:
            return FlickerResult(
                frequencyHz: 98,
                modulationDepthPercent: 31.2,
                verdict: .exceedsLowRisk,
                presence: .present,
                confidence: .low,
                tier: .tier1,
                diagnosticNote: "Signal was close to the noise floor; measure again closer to the fixture."
            )
        case .failsInsufficientSignal:
            throw AnalysisError.insufficientSignal(reason: "fake scenario")
        case .failsAmbiguous:
            throw AnalysisError.ambiguousFrequency(candidates: [100, 300])
        case .failsSaturated:
            throw AnalysisError.sensorSaturated
        }
    }
}

public enum CalibrationScenario: String, Sendable, CaseIterable {
    case succeeds
    /// A solver locked onto the wrong harmonic.
    case implausiblyLarge
    case implausiblySmall
    case failsInsufficientSignal
}

public struct FakeDeviceCalibrator: DeviceCalibrating {
    public let scenario: CalibrationScenario
    public let latency: Duration

    public init(scenario: CalibrationScenario = .succeeds, latency: Duration = .milliseconds(900)) {
        self.scenario = scenario
        self.latency = latency
    }

    public func solveLineReadoutTime(
        from frames: FrameSequence,
        knownFrequencyHz: Double
    ) async throws -> TimeInterval {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        try Task.checkCancellation()

        let solved: TimeInterval
        switch scenario {
        case .succeeds:
            solved = 18.5e-6
        case .implausiblyLarge:
            solved = 900e-6
        case .implausiblySmall:
            solved = 0.1e-6
        case .failsInsufficientSignal:
            throw AnalysisError.insufficientSignal(reason: "fake scenario")
        }

        guard DeviceCalibration.isPlausible(solved) else {
            throw AnalysisError.implausibleCalibration(
                solved: solved,
                plausible: DeviceCalibration.plausibleLineReadoutRange
            )
        }
        return solved
    }
}
#endif
