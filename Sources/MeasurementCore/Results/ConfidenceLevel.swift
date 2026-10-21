import Foundation

extension FlickerResult {
    public static let maxConfidenceLevel = 5

    /// Presentation only: "Tier 3" tested as jargon. Tier dominates, but a clean Tier 2
    /// deliberately ties a shaky Tier 1.
    public var confidenceLevel: Int {
        switch (tier, confidence) {
        case (.tier3, .low), (.tier3, .medium): return 1
        case (.tier3, .high), (.tier2, .low): return 2
        case (.tier2, .medium), (.tier1, .low): return 3
        case (.tier2, .high), (.tier1, .medium): return 4
        case (.tier1, .high): return 5
        }
    }

    public var formattedConfidenceLevel: String {
        "Confidence level: \(confidenceLevel)/\(Self.maxConfidenceLevel)"
    }
}
