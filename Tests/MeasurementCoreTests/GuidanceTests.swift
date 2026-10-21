import Foundation
import Testing
@testable import MeasurementCore

@Suite("Guidance")
struct GuidanceTests {

    private static func flicker(
        frequencyHz: Double? = nil,
        modulationDepthPercent: Double? = nil,
        verdict: IEEE1789Verdict? = nil,
        presence: FlickerPresence,
        tier: MeasurementTier
    ) -> FlickerResult {
        FlickerResult(
            frequencyHz: frequencyHz,
            modulationDepthPercent: modulationDepthPercent,
            verdict: verdict,
            presence: presence,
            confidence: .high,
            tier: tier
        )
    }

    @Test("Feeding the same result in twice yields identical guidance")
    func deterministic() {
        let result = Self.flicker(
            frequencyHz: 100, modulationDepthPercent: 40, verdict: .exceedsLowRisk,
            presence: .present, tier: .tier1
        )
        let first = Guidance.rules(for: result)
        let second = Guidance.rules(for: result)
        #expect(first == second)
        #expect(first.map(\.finding) == [.exceedsLowRiskLimit90To1250Hz])
    }

    @Test("A Tier 1 result exceeding the low-risk limit below 90 Hz gets the low-frequency guidance")
    func exceedsLowRiskLimitBelow90HzFinding() {
        let result = Self.flicker(
            frequencyHz: 60, modulationDepthPercent: 6, verdict: .exceedsLowRisk,
            presence: .present, tier: .tier1
        )
        let findings = Guidance.findings(for: result)
        #expect(findings == [.exceedsLowRiskLimitBelow90Hz])
        let rules = Guidance.rules(for: result)
        #expect(!rules.isEmpty)
        #expect(rules.allSatisfy { !$0.sources.isEmpty })
        #expect(rules.flatMap(\.sources).allSatisfy { $0.url != nil })
    }

    @Test("A Tier 1 result exceeding the low-risk limit at or above 90 Hz gets the high-frequency guidance")
    func exceedsLowRiskLimit90To1250HzFinding() {
        // IEEE1789 puts exactly 90 Hz in the upper band, so guidance must agree.
        let onBoundary = Self.flicker(
            frequencyHz: 90, modulationDepthPercent: 8, verdict: .exceedsLowRisk,
            presence: .present, tier: .tier1
        )
        let aboveBoundary = Self.flicker(
            frequencyHz: 500, modulationDepthPercent: 45, verdict: .exceedsLowRisk,
            presence: .present, tier: .tier1
        )
        #expect(Guidance.findings(for: onBoundary) == [.exceedsLowRiskLimit90To1250Hz])
        #expect(Guidance.findings(for: aboveBoundary) == [.exceedsLowRiskLimit90To1250Hz])
        let rules = Guidance.rules(for: aboveBoundary)
        #expect(!rules.isEmpty)
        #expect(rules.allSatisfy { !$0.sources.isEmpty })
        #expect(rules.flatMap(\.sources).allSatisfy { $0.url != nil })
    }

    @Test("A Tier 1 result within the low-risk range gets no guidance")
    func withinLimitsNoFinding() {
        let noEffect = Self.flicker(
            frequencyHz: 3_000, modulationDepthPercent: 1.4, verdict: .noObservableEffect,
            presence: .present, tier: .tier1
        )
        let lowRisk = Self.flicker(
            frequencyHz: 120, modulationDepthPercent: 7.2, verdict: .lowRisk,
            presence: .present, tier: .tier1
        )
        #expect(Guidance.findings(for: noEffect).isEmpty)
        #expect(Guidance.findings(for: lowRisk).isEmpty)
    }

    @Test("A Tier 1 result with no flicker present gets no guidance")
    func absentNoFinding() {
        let result = Self.flicker(presence: .absent, tier: .tier1)
        #expect(Guidance.findings(for: result).isEmpty)
    }

    @Test("Flicker detected at Tier 2 or Tier 3 gets the not-graded guidance, never a depth-based one")
    func detectedNotGradedFinding() {
        let tier2 = Self.flicker(frequencyHz: 100, presence: .present, tier: .tier2)
        let tier3 = Self.flicker(presence: .present, tier: .tier3)
        #expect(Guidance.findings(for: tier2) == [.detectedNotGraded])
        #expect(Guidance.findings(for: tier3) == [.detectedNotGraded])
        #expect(Guidance.rules(for: tier2).first?.sources.first?.url == nil)
    }

    @Test("An indeterminate result produces no guidance")
    func indeterminateNoFinding() {
        let result = Self.flicker(presence: .indeterminate, tier: .tier3)
        #expect(Guidance.findings(for: result).isEmpty)
        #expect(Guidance.rules(for: result).isEmpty)
    }

    @Test("Every rule's finding matches its own dictionary key")
    func rulesKeyedConsistently() {
        for (finding, rule) in Guidance.rules {
            #expect(finding == rule.finding)
            #expect(!rule.title.isEmpty)
            #expect(!rule.actions.isEmpty)
            #expect(!rule.sources.isEmpty)
            #expect(rule.sources.allSatisfy { !$0.name.isEmpty })
        }
    }
}
