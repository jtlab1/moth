import Foundation

public enum IEEE1789Verdict: String, Sendable, Codable, CaseIterable {
    case noObservableEffect
    case lowRisk
    case exceedsLowRisk
}

extension IEEE1789Verdict {
    /// Plain words rather than the standard's terms; casual users have no frame for "IEEE 1789".
    public var title: String {
        switch self {
        case .noObservableEffect: return "Looks good"
        case .lowRisk: return "Mild flicker"
        case .exceedsLowRisk: return "Strong flicker"
        }
    }

    public var explanation: String {
        switch self {
        case .noObservableEffect:
            return "This light's flicker is faint enough that most people won't notice it or be bothered by it."
        case .lowRisk:
            return "This light flickers, but at a level most people won't be bothered by."
        case .exceedsLowRisk:
            return "This light flickers more than is generally considered safe. It may cause discomfort, headache, or eye strain for sensitive people."
        }
    }

    /// Distinct silhouettes, not one shape in three colours, so colour-blind users get the verdict.
    public var iconName: String {
        switch self {
        case .noObservableEffect: return "checkmark.circle.fill"
        case .lowRisk: return "minus.circle.fill"
        case .exceedsLowRisk: return "exclamationmark.triangle.fill"
        }
    }
}

/// Populated at every tier because at Tier 3 it is the whole result.
public enum FlickerPresence: String, Sendable, Codable {
    case present
    /// A real finding: daylight and DC-driven LEDs land here.
    case absent
    /// No measurement was possible, unlike `.absent`.
    case indeterminate
}

extension FlickerPresence {
    public var title: String {
        switch self {
        case .present: return "Flicker detected"
        case .absent: return "No flicker detected"
        case .indeterminate: return "Inconclusive"
        }
    }

    public var iconName: String {
        switch self {
        case .present: return "waveform"
        case .absent: return "checkmark.circle.fill"
        case .indeterminate: return "questionmark.circle.fill"
        }
    }
}

/// Orthogonal to tier: how well this capture went, not what the hardware can recover.
public enum MeasurementConfidence: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }

    public var explanation: String {
        switch self {
        case .low:
            return "The signal was weak or unsteady. Try again holding the phone still, closer to the light."
        case .medium:
            return "The signal was usable but not ideal. A steadier capture would tighten these numbers."
        case .high:
            return "The signal was clean and steady."
        }
    }
}

/// The initialiser silently drops fields the tier can't support, so no view can leak one.
/// Silent rather than trapping so analysers can hand over everything and let the tier decide.
public struct FlickerResult: Sendable, Codable, Hashable {
    public let frequencyHz: Double?

    /// IEEE 1789's `(max - min) / (max + min) × 100`.
    public let modulationDepthPercent: Double?
    public let verdict: IEEE1789Verdict?
    public let presence: FlickerPresence
    public let confidence: MeasurementConfidence
    public let tier: MeasurementTier
    public let analyzedAt: Date

    /// Not an error; errors throw.
    public let diagnosticNote: String?

    public init(
        frequencyHz: Double? = nil,
        modulationDepthPercent: Double? = nil,
        verdict: IEEE1789Verdict? = nil,
        presence: FlickerPresence,
        confidence: MeasurementConfidence,
        tier: MeasurementTier,
        analyzedAt: Date = Date(),
        diagnosticNote: String? = nil
    ) {
        self.frequencyHz = tier.supportsFrequency ? frequencyHz : nil
        self.modulationDepthPercent = tier.supportsModulationDepth ? modulationDepthPercent : nil
        self.verdict = tier.supportsVerdict ? verdict : nil
        self.presence = presence
        self.confidence = confidence
        self.tier = tier
        self.analyzedAt = analyzedAt
        self.diagnosticNote = diagnosticNote
    }
}

/// Worst sorts highest. `.detectedUnrated` outranks `.lowRisk`: an ungraded flickering fixture
/// deserves a visit more than one checked and found benign.
public enum FlickerSeverity: Int, Sendable, Codable, CaseIterable, Comparable {
    case unknown = 0
    case none = 1
    case noObservableEffect = 2
    case lowRisk = 3
    case detectedUnrated = 4
    case exceedsLowRisk = 5

    public static func < (lhs: FlickerSeverity, rhs: FlickerSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Matches `IEEE1789Verdict.title` so the two badges never describe one thing two ways.
    public var title: String {
        switch self {
        case .unknown: return "Inconclusive"
        case .none: return "No flicker"
        case .noObservableEffect: return "Looks good"
        case .lowRisk: return "Mild flicker"
        case .detectedUnrated: return "Flicker detected, not graded"
        case .exceedsLowRisk: return "Strong flicker"
        }
    }

    public var iconName: String {
        switch self {
        case .unknown: return "questionmark.circle.fill"
        case .none: return "checkmark.circle.fill"
        case .noObservableEffect: return "checkmark.circle.fill"
        case .lowRisk: return "minus.circle.fill"
        case .detectedUnrated: return "waveform"
        case .exceedsLowRisk: return "exclamationmark.triangle.fill"
        }
    }
}

extension FlickerResult {
    public var severity: FlickerSeverity {
        if let verdict {
            switch verdict {
            case .noObservableEffect: return .noObservableEffect
            case .lowRisk: return .lowRisk
            case .exceedsLowRisk: return .exceedsLowRisk
            }
        }
        switch presence {
        case .present: return .detectedUnrated
        case .absent: return .none
        case .indeterminate: return .unknown
        }
    }

    /// Whole Hz: a decimal implies precision the capture doesn't have.
    public var formattedFrequency: String? {
        frequencyHz.map { "\(Int($0.rounded())) Hz" }
    }

    public var formattedModulationDepth: String? {
        modulationDepthPercent.map { String(format: "%.1f%%", $0) }
    }

}
