import Foundation

// The seam between the app and the signal processing. Don't change these signatures casually.

/// Must honor cancellation, clamp the tier to the device, return `.absent` for a steady light instead of throwing,
/// and not hold onto `frames` after returning since the caller recycles them.
public protocol FlickerAnalyzing: Sendable {
    func analyze(frames: FrameSequence, metadata: CaptureMetadata) async throws -> FlickerResult
}

/// Must throw `implausibleCalibration` instead of returning an out-of-range value,
/// since a bad calibration gives confident wrong frequencies forever.
public protocol DeviceCalibrating: Sendable {
    func solveLineReadoutTime(from frames: FrameSequence, knownFrequencyHz: Double) async throws -> TimeInterval

    /// `sweep` is one sequence per ISO step on the same scene. Throw `responseCurveUnsolvable`
    /// instead of returning a curve that fails the checks.
    func solveResponseCurve(from sweep: [FrameSequence]) async throws -> ResponseCurve
}
