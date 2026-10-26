import Foundation

/// Failures to measure only. "No flicker" is `FlickerPresence.absent`, a finding, not an error.
public enum AnalysisError: Error, Sendable, Equatable {
    /// `reason` is for the log, not the user.
    case insufficientSignal(reason: String)
    case tooFewFrames(captured: Int, required: Int)
    case captureTooShort(duration: TimeInterval, required: TimeInterval)
    case sensorSaturated

    /// Carries the candidates so the UI can say what it's torn between instead of picking one.
    case ambiguousFrequency(candidates: [Double])
    case implausibleCalibration(solved: TimeInterval, plausible: ClosedRange<TimeInterval>)

    /// Calibration only: the reference light showed no flicker at the mains rate. Usually an
    /// LED, which is a finding about the light, not a lack of light. `reason` is for the log.
    case referenceFlickerNotFound(reason: String)

    /// Calibration only: the camera ran at a rate in step with the reference (30 fps under
    /// 120 Hz), so the light's phase never drifts between frames and can't be timed.
    case frameRateLockedToLight(frameRate: Double, lightHz: Double)

    /// Calibration only: the sensor reads the buffer's last row first, which the analysis
    /// doesn't support. Refused rather than solved, because it can mimic a wrong readout time.
    case readoutDirectionReversed

    /// The ISO sweep couldn't yield a trustworthy response curve. Not fatal to calibration:
    /// frequency still works, depth stays off. `reason` is for the log, not the user.
    case responseCurveUnsolvable(reason: String)
    case unsupportedPixelFormat(UInt32)
    case pixelBufferUnreadable(frameIndex: Int, code: Int)

    /// Never shown as an error.
    case cancelled
}

extension AnalysisError {

    /// No jargon, no error codes, no blame.
    public var userFacingMessage: String {
        switch self {
        case .insufficientSignal:
            return "There wasn't enough light signal to measure."
        case .tooFewFrames:
            return "The camera didn't deliver enough frames to measure."
        case .captureTooShort:
            return "The capture ended too soon to measure."
        case .sensorSaturated:
            return "The light was too bright for the camera to measure accurately."
        case .ambiguousFrequency(let candidates):
            let list = candidates.map { "\(Int($0.rounded())) Hz" }.joined(separator: " or ")
            return "This light could be flickering at \(list) — one capture can't tell them apart."
        case .implausibleCalibration:
            return "Calibration produced a result that can't be right, so it wasn't saved."
        case .referenceFlickerNotFound:
            return "Moth couldn't see this light flicker, so it can't calibrate from it."
        case .frameRateLockedToLight(let frameRate, _):
            return "The camera ran at \(Int(frameRate.rounded())) frames per second instead of 29, in step with this light's flicker, so the flicker couldn't be timed."
        case .readoutDirectionReversed:
            return "This iPhone's camera reads out its picture in the opposite direction from what Moth expects, so calibration can't finish yet."
        case .responseCurveUnsolvable:
            return "Moth couldn't work out how this camera responds to light, so it can measure how fast a light flickers but not how deep."
        case .unsupportedPixelFormat:
            return "The camera returned a format Moth can't read."
        case .pixelBufferUnreadable:
            return "Some camera frames couldn't be read."
        case .cancelled:
            return "Measurement cancelled."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .insufficientSignal:
            return "Point the phone directly at the light fixture and hold it steady."
        case .tooFewFrames:
            return "Try again. If the phone is warm, let it cool for a minute first."
        case .captureTooShort:
            return "Hold the phone still until the countdown finishes."
        case .sensorSaturated:
            return "Aim at a wall or ceiling the light shines on instead of the bulb itself, or step back. If it still happens, try again with less daylight falling on that spot."
        case .ambiguousFrequency:
            return "Move a little closer or further away and measure again."
        case .implausibleCalibration:
            return "Try calibration again using an older fluorescent or incandescent fixture, not an LED."
        case .referenceFlickerNotFound:
            return "Calibration needs a light that flickers with the mains supply, such as an older fluorescent tube or an incandescent bulb. Most LED lights flicker too little. Point the top of the phone at the fixture and hold still."
        case .frameRateLockedToLight:
            return "Close any other app using the camera, then try again. If it keeps happening, restart the phone."
        case .readoutDirectionReversed:
            return "Nothing was saved. Please report this along with your iPhone model."
        case .responseCurveUnsolvable:
            return "Try again under the same light, holding the phone still and pointed at an evenly lit surface."
        case .unsupportedPixelFormat, .pixelBufferUnreadable:
            return "Close and reopen Moth, then try again."
        case .cancelled:
            return nil
        }
    }
}

extension AnalysisError: LocalizedError {
    public var errorDescription: String? { userFacingMessage }
    public var failureReason: String? { userFacingMessage }
}
