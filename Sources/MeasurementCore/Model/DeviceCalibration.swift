import Foundation

public struct DeviceCalibration: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID

    /// Checked before use: a calibration restored onto different hardware is meaningless.
    public let deviceModelIdentifier: String
    public let lineReadoutTime: TimeInterval
    public let referenceFrequencyHz: Double

    /// Readout time belongs to a format, not just a device.
    public let calibratedLineCount: Int

    /// The capture the readout time and response curve were solved under; checked before use.
    public let format: CaptureFormatSignature

    /// `nil` when the sweep failed or never ran: frequency still works, depth (Tier 1) doesn't.
    public let responseCurve: ResponseCurve?

    /// Bumped whenever the measurement method changes what a calibration means.
    public let calibrationVersion: Int

    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        deviceModelIdentifier: String,
        lineReadoutTime: TimeInterval,
        referenceFrequencyHz: Double,
        calibratedLineCount: Int,
        format: CaptureFormatSignature,
        responseCurve: ResponseCurve? = nil,
        calibrationVersion: Int = DeviceCalibration.currentVersion,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.deviceModelIdentifier = deviceModelIdentifier
        self.lineReadoutTime = lineReadoutTime
        self.referenceFrequencyHz = referenceFrequencyHz
        self.calibratedLineCount = calibratedLineCount
        self.format = format
        self.responseCurve = responseCurve
        self.calibrationVersion = calibrationVersion
        self.capturedAt = capturedAt
    }
}

extension DeviceCalibration {
    /// 2 is the capture standard (29 fps, 1/4000 s, keyed by format). Version 1 is never used.
    public static let currentVersion = 2

    /// 1 to 100 µs, a loose bound for callers that don't know the format. Prefer `plausibleLineReadoutRange(for:)`.
    public static let plausibleLineReadoutRange: ClosedRange<TimeInterval> = 1e-6...1e-4

    public static func isPlausible(_ lineReadoutTime: TimeInterval) -> Bool {
        plausibleLineReadoutRange.contains(lineReadoutTime)
    }

    /// Reading every row can't take longer than a frame, so anything above that (plus 2% slack) is a harmonic lock-on.
    public static func plausibleLineReadoutRange(for format: CaptureFormatSignature) -> ClosedRange<TimeInterval> {
        let lower = plausibleLineReadoutRange.lowerBound
        guard format.frameRate > 0, format.height > 0 else { return lower...lower }
        let upper = (1 / format.frameRate) / Double(format.height) * 1.02
        return lower...max(lower, upper)
    }

    public static func isPlausible(_ lineReadoutTime: TimeInterval, for format: CaptureFormatSignature) -> Bool {
        plausibleLineReadoutRange(for: format).contains(lineReadoutTime)
    }

    /// Healthy back-to-back solves agree well under 1%; 3% leaves room for framing and exposure noise.
    public static let agreementTolerance: Double = 0.03

    public static func agree(_ first: TimeInterval, _ second: TimeInterval) -> Bool {
        guard first > 0, second > 0 else { return false }
        let relativeDifference = abs(first - second) / max(first, second)
        return relativeDifference <= agreementTolerance
    }

    /// Same hardware, current method, same format; if any differ, the calibration describes a different capture.
    public func appliesTo(modelIdentifier: String, format: CaptureFormatSignature) -> Bool {
        deviceModelIdentifier == modelIdentifier
            && isCurrentVersion
            && self.format.matches(format)
    }

    public var isCurrentVersion: Bool { calibrationVersion == Self.currentVersion }

    /// e.g. "18.5 µs per line".
    public var formattedLineReadoutTime: String {
        String(format: "%.2f µs per line", lineReadoutTime * 1_000_000)
    }

}

public enum CalibrationState: Sendable, Equatable {
    case uncalibrated
    case calibrated(DeviceCalibration)

    /// Solved on different hardware (a restored backup); not applied.
    case foreignDevice(DeviceCalibration)

    /// This device, but an older method or different format, so it's not applied and the user recalibrates once.
    case outdated(DeviceCalibration)
    case rejected(solved: TimeInterval, attemptedAt: Date)

    public var usableCalibration: DeviceCalibration? {
        if case .calibrated(let calibration) = self { return calibration }
        return nil
    }

    public var isCalibrated: Bool { usableCalibration != nil }

    public var isOutdated: Bool {
        if case .outdated = self { return true }
        return false
    }
}
