import Foundation

/// Which quantities are recoverable at all, not a quality score: a Tier 3 reading is a
/// smaller claim, not a worse one.
public enum MeasurementTier: String, Sendable, Codable, CaseIterable {
    /// Recoverable: frequency, modulation depth, IEEE 1789 verdict.
    case tier1

    /// Line readout time known, but amplitude can't be trusted: the camera's light response
    /// hasn't been measured, or this capture couldn't hold the standard exposure.
    /// Recoverable: frequency.
    case tier2

    /// Uncalibrated (or calibrated under an older method), so rows can't map to time.
    /// Recoverable: presence only.
    case tier3
}

extension MeasurementTier {
    public var supportsFrequency: Bool {
        switch self {
        case .tier1, .tier2: return true
        case .tier3: return false
        }
    }

    public var supportsModulationDepth: Bool { self == .tier1 }

    public var supportsVerdict: Bool { self == .tier1 }

    public var headline: String {
        switch self {
        case .tier1: return "Full measurement"
        case .tier2: return "Frequency only"
        case .tier3: return "Presence only"
        }
    }

    /// Says what the device can do, never "your device is bad".
    public var explanation: String {
        switch self {
        case .tier1:
            return """
            This iPhone is calibrated and held Moth's standard exposure, so Moth can \
            measure how fast the light flickers, how deep the flicker is, and compare \
            both against the IEEE 1789 guideline.
            """
        case .tier2:
            return """
            This iPhone is calibrated, so Moth can measure how fast the light \
            flickers, and the frequency shown is a real measurement. It couldn't \
            measure how deep the flicker is this time: either calibration hasn't yet \
            measured how this camera responds to light (recalibrating can finish that \
            step), or the camera couldn't hold Moth's standard exposure during this \
            capture. Without depth there is no honest way to give an IEEE 1789 verdict.
            """
        case .tier3:
            return """
            This iPhone has not been calibrated for Moth's current measurement method, \
            so Moth can tell you whether the light is flickering but not how fast. \
            Running Calibration once, using an older fluorescent or incandescent \
            fixture, unlocks frequency and depth measurement.
            """
        }
    }

}

extension MeasurementTier: Comparable {
    /// `min(a, b)` is the conservative choice; analysis may lower a tier, never raise it.
    private var capabilityRank: Int {
        switch self {
        case .tier3: return 0
        case .tier2: return 1
        case .tier1: return 2
        }
    }

    public static func < (lhs: MeasurementTier, rhs: MeasurementTier) -> Bool {
        lhs.capabilityRank < rhs.capabilityRank
    }
}
