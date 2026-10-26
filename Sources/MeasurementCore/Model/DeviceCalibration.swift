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
    /// 2 is the capture standard (fixed 29 fps, 1/4000 s, format-keyed). Everything persisted
    /// before it is version 1 and never used.
    public static let currentVersion = 2

    /// 1–100 µs, a format-agnostic outer bound. Prefer `plausibleLineReadoutRange(for:)`,
    /// which is far tighter; this remains for callers that don't know the format.
    public static let plausibleLineReadoutRange: ClosedRange<TimeInterval> = 1e-6...1e-4

    public static func isPlausible(_ lineReadoutTime: TimeInterval) -> Bool {
        plausibleLineReadoutRange.contains(lineReadoutTime)
    }

    /// Reading out every buffer row can't take longer than a frame period, so a readout time
    /// above `(1 / fps) / height` (plus 2% for timing slack) can only be a harmonic lock-on.
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

    /// Same hardware, current method, same capture format. Any one failing means the
    /// readout time (or curve) describes a different capture than the one being analysed.
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

    /// This device, but an older method or a different capture format; not applied. The user
    /// is asked to recalibrate once.
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
