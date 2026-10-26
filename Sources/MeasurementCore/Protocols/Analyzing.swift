import Foundation

// The seam between the app and the signal processing. Signatures are fixed: changing
// one is a conversation, not a commit.

/// Must honour cancellation, clamp the tier with `metadata.deviceCapability.clampedTier(_:)`,
/// return `.absent` rather than throw for a non-flickering light, and not retain `frames`
/// past the call (the caller recycles them immediately).
public protocol FlickerAnalyzing: Sendable {
    func analyze(frames: FrameSequence, metadata: CaptureMetadata) async throws -> FlickerResult
}

/// Must throw `implausibleCalibration` rather than return a value outside
/// `DeviceCalibration.plausibleLineReadoutRange(for:)`: a wrong calibration yields confident,
/// wrong frequencies forever.
public protocol DeviceCalibrating: Sendable {
    func solveLineReadoutTime(from frames: FrameSequence, knownFrequencyHz: Double) async throws -> TimeInterval

    /// `sweep` is one sequence per ISO step at the standard exposure, on the same scene; each
    /// frame carries its read-back ISO. Must throw `responseCurveUnsolvable` rather than return
    /// a curve that fails the acceptance checks (monotone, residual, code coverage).
    func solveResponseCurve(from sweep: [FrameSequence]) async throws -> ResponseCurve
}
