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

/// The init quietly drops fields the tier can't support so no view can leak one,
/// and analyzers can just hand over everything.
public struct FlickerResult: Sendable, Hashable {
    /// Bumped when the analysis method changes what a result means. Pre-version-2 results decode as 1.
    public static let currentAnalysisVersion = 2

    public let frequencyHz: Double?

    /// IEEE 1789's `(max - min) / (max + min) × 100`.
    public let modulationDepthPercent: Double?
    public let verdict: IEEE1789Verdict?
    public let presence: FlickerPresence
    public let confidence: MeasurementConfidence
    public let tier: MeasurementTier
    public let analyzedAt: Date

    /// Not errors; errors throw. Each says which condition cost confidence or a quantity.
    public let diagnosticNotes: [String]

    /// `nil` for results from before the capture standard.
    public let conditions: CaptureConditions?

    /// `nil` when unknown (older results); `false` means depth stayed in code units.
    public let responseCurveApplied: Bool?
    public let analysisVersion: Int

    /// `diagnosticNote` is kept for older call sites and is prepended to `diagnosticNotes`.
    public init(
        frequencyHz: Double? = nil,
        modulationDepthPercent: Double? = nil,
        verdict: IEEE1789Verdict? = nil,
        presence: FlickerPresence,
        confidence: MeasurementConfidence,
        tier: MeasurementTier,
        analyzedAt: Date = Date(),
        diagnosticNote: String? = nil,
        diagnosticNotes: [String] = [],
        conditions: CaptureConditions? = nil,
        responseCurveApplied: Bool? = nil,
        analysisVersion: Int = FlickerResult.currentAnalysisVersion
    ) {
        self.frequencyHz = tier.supportsFrequency ? frequencyHz : nil
        self.modulationDepthPercent = tier.supportsModulationDepth ? modulationDepthPercent : nil
        self.verdict = tier.supportsVerdict ? verdict : nil
        self.presence = presence
        self.confidence = confidence
        self.tier = tier
        self.analyzedAt = analyzedAt
        self.diagnosticNotes = (diagnosticNote.map { [$0] } ?? []) + diagnosticNotes
        self.conditions = conditions
        self.responseCurveApplied = responseCurveApplied
        self.analysisVersion = analysisVersion
    }

    /// The first note, for views that show one line.
    public var diagnosticNote: String? { diagnosticNotes.first }
}

// Hand-written so pre-version-2 results still decode, and goes through `init` so the tier gate re-applies.
extension FlickerResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case frequencyHz, modulationDepthPercent, verdict, presence, confidence, tier, analyzedAt
        case diagnosticNote, diagnosticNotes, conditions, responseCurveApplied, analysisVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let notes = try container.decodeIfPresent([String].self, forKey: .diagnosticNotes)
        let legacyNote = try container.decodeIfPresent(String.self, forKey: .diagnosticNote)
        self.init(
            frequencyHz: try container.decodeIfPresent(Double.self, forKey: .frequencyHz),
            modulationDepthPercent: try container.decodeIfPresent(Double.self, forKey: .modulationDepthPercent),
            verdict: try container.decodeIfPresent(IEEE1789Verdict.self, forKey: .verdict),
            presence: try container.decode(FlickerPresence.self, forKey: .presence),
            confidence: try container.decode(MeasurementConfidence.self, forKey: .confidence),
            tier: try container.decode(MeasurementTier.self, forKey: .tier),
            analyzedAt: try container.decode(Date.self, forKey: .analyzedAt),
            diagnosticNote: notes == nil ? legacyNote : nil,
            diagnosticNotes: notes ?? [],
            conditions: try container.decodeIfPresent(CaptureConditions.self, forKey: .conditions),
            responseCurveApplied: try container.decodeIfPresent(Bool.self, forKey: .responseCurveApplied),
            analysisVersion: try container.decodeIfPresent(Int.self, forKey: .analysisVersion) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(frequencyHz, forKey: .frequencyHz)
        try container.encodeIfPresent(modulationDepthPercent, forKey: .modulationDepthPercent)
        try container.encodeIfPresent(verdict, forKey: .verdict)
        try container.encode(presence, forKey: .presence)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(tier, forKey: .tier)
        try container.encode(analyzedAt, forKey: .analyzedAt)
        // The legacy key too, so an older build reading this store still shows a note.
        try container.encodeIfPresent(diagnosticNote, forKey: .diagnosticNote)
        try container.encode(diagnosticNotes, forKey: .diagnosticNotes)
        try container.encodeIfPresent(conditions, forKey: .conditions)
        try container.encodeIfPresent(responseCurveApplied, forKey: .responseCurveApplied)
        try container.encode(analysisVersion, forKey: .analysisVersion)
    }
}

/// Worst sorts highest. An ungraded flickering fixture outranks `.lowRisk` since it's more worth a look.
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
