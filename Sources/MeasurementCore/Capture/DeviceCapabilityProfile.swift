import Foundation

/// Travels with every capture so analysis never has to ask the device anything.
public struct DeviceCapabilityProfile: Sendable, Codable, Hashable {
    public let modelIdentifier: String
    public let supportsManualExposure: Bool
    public let exposureDurationRange: ClosedRange<TimeInterval>
    public let isoRange: ClosedRange<Float>
    public let maximumFrameRate: Double

    /// The gate on modulation depth: amplitude through an unknown tone curve isn't a measurement.
    public let providesLinearCapture: Bool
    public let isCalibrated: Bool

    public init(
        modelIdentifier: String,
        supportsManualExposure: Bool,
        exposureDurationRange: ClosedRange<TimeInterval>,
        isoRange: ClosedRange<Float>,
        maximumFrameRate: Double,
        providesLinearCapture: Bool,
        isCalibrated: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.supportsManualExposure = supportsManualExposure
        self.exposureDurationRange = exposureDurationRange
        self.isoRange = isoRange
        self.maximumFrameRate = maximumFrameRate
        self.providesLinearCapture = providesLinearCapture
        self.isCalibrated = isCalibrated
    }
}

extension DeviceCapabilityProfile {
    public var maximumAttainableTier: MeasurementTier {
        guard isCalibrated else { return .tier3 }
        guard supportsManualExposure && providesLinearCapture else { return .tier2 }
        return .tier1
    }

    /// Use instead of returning a tier directly, so over-claiming is impossible to forget.
    public func clampedTier(_ proposed: MeasurementTier) -> MeasurementTier {
        min(proposed, maximumAttainableTier)
    }
}
