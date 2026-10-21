import Foundation
import Testing
@testable import MeasurementCore

@Suite("Confidence level")
struct ConfidenceLevelTests {

    private static func flicker(tier: MeasurementTier, confidence: MeasurementConfidence) -> FlickerResult {
        FlickerResult(presence: .present, confidence: confidence, tier: tier)
    }

    @Test(
        "Every (tier, confidence) combination maps to the documented table",
        arguments: [
            (MeasurementTier.tier3, MeasurementConfidence.low, 1),
            (.tier3, .medium, 1),
            (.tier3, .high, 2),
            (.tier2, .low, 2),
            (.tier2, .medium, 3),
            (.tier2, .high, 4),
            (.tier1, .low, 3),
            (.tier1, .medium, 4),
            (.tier1, .high, 5)
        ]
    )
    func mapsToDocumentedTable(tier: MeasurementTier, confidence: MeasurementConfidence, expected: Int) {
        #expect(Self.flicker(tier: tier, confidence: confidence).confidenceLevel == expected)
    }

    @Test("Every combination falls within 1...maxConfidenceLevel")
    func staysInRange() {
        for tier in MeasurementTier.allCases {
            for confidence in MeasurementConfidence.allCases {
                let level = Self.flicker(tier: tier, confidence: confidence).confidenceLevel
                #expect((1...FlickerResult.maxConfidenceLevel).contains(level))
            }
        }
    }

    @Test("A higher tier never scores lower than a worse tier at the same confidence")
    func tierDominatesAtEqualConfidence() {
        for confidence in MeasurementConfidence.allCases {
            let tier3 = Self.flicker(tier: .tier3, confidence: confidence).confidenceLevel
            let tier2 = Self.flicker(tier: .tier2, confidence: confidence).confidenceLevel
            let tier1 = Self.flicker(tier: .tier1, confidence: confidence).confidenceLevel
            #expect(tier3 < tier2)
            #expect(tier2 < tier1)
        }
    }

    @Test("formattedConfidenceLevel reads as \"Confidence level: N/5\"")
    func formattedString() {
        let result = Self.flicker(tier: .tier1, confidence: .high)
        #expect(result.formattedConfidenceLevel == "Confidence level: 5/5")
    }
}
