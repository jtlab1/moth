import Foundation

public struct DeviceCalibration: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID

    /// Checked before use: a calibration restored onto different hardware is meaningless.
    public let deviceModelIdentifier: String
    public let lineReadoutTime: TimeInterval
    public let referenceFrequencyHz: Double

    /// Readout time belongs to a format, not just a device.
    public let calibratedLineCount: Int

    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        deviceModelIdentifier: String,
        lineReadoutTime: TimeInterval,
        referenceFrequencyHz: Double,
        calibratedLineCount: Int,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.deviceModelIdentifier = deviceModelIdentifier
        self.lineReadoutTime = lineReadoutTime
        self.referenceFrequencyHz = referenceFrequencyHz
        self.calibratedLineCount = calibratedLineCount
        self.capturedAt = capturedAt
    }
}

extension DeviceCalibration {
    /// 1–100 µs, deliberately wider than the real ~2–50 µs: it exists to catch a solver locked
    /// onto a harmonic, and no frequency at all beats one scaled by ten.
    public static let plausibleLineReadoutRange: ClosedRange<TimeInterval> = 1e-6...1e-4

    public static func isPlausible(_ lineReadoutTime: TimeInterval) -> Bool {
        plausibleLineReadoutRange.contains(lineReadoutTime)
    }

    /// Healthy back-to-back solves agree well under 1%; 3% leaves room for framing and exposure noise.
    public static let agreementTolerance: Double = 0.03

    public static func agree(_ first: TimeInterval, _ second: TimeInterval) -> Bool {
        guard first > 0, second > 0 else { return false }
        let relativeDifference = abs(first - second) / max(first, second)
        return relativeDifference <= agreementTolerance
    }

    public func appliesTo(modelIdentifier: String) -> Bool {
        deviceModelIdentifier == modelIdentifier
    }

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
    case rejected(solved: TimeInterval, attemptedAt: Date)

    public var usableCalibration: DeviceCalibration? {
        if case .calibrated(let calibration) = self { return calibration }
        return nil
    }

    public var isCalibrated: Bool { usableCalibration != nil }
}
