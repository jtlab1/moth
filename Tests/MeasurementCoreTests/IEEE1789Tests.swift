import Foundation
import Testing
@testable import MeasurementCore

@Suite("IEEE 1789 thresholds")
struct IEEE1789Tests {

    @Test("Below 90 Hz uses the shallow slopes")
    func belowBoundary() {
        #expect(IEEE1789.noObservableEffectLimitPercent(frequencyHz: 50) == 0.5)   // 0.01 × 50
        #expect(IEEE1789.lowRiskLimitPercent(frequencyHz: 50) == 1.25)             // 0.025 × 50
    }

    @Test("90 Hz and above uses the steeper slopes")
    func aboveBoundary() {
        let noEffect = try! #require(IEEE1789.noObservableEffectLimitPercent(frequencyHz: 100))
        let lowRisk = try! #require(IEEE1789.lowRiskLimitPercent(frequencyHz: 100))
        #expect(abs(noEffect - 3.33) < 1e-9)   // 0.0333 × 100
        #expect(abs(lowRisk - 8.0) < 1e-9)     // 0.08 × 100
        #expect(abs(try! #require(IEEE1789.lowRiskLimitPercent(frequencyHz: 120)) - 9.6) < 1e-9)
    }

    @Test("The discontinuity sits exactly at 90 Hz")
    func discontinuity() {
        // The jump at 90 Hz is in the standard, not a rounding artefact.
        #expect(abs(try! #require(IEEE1789.lowRiskLimitPercent(frequencyHz: 90)) - 7.2) < 1e-9)
        #expect(abs(try! #require(IEEE1789.lowRiskLimitPercent(frequencyHz: 89.999)) - 2.2499750) < 1e-6)
    }

    @Test("Above 1250 Hz the standard places no limit")
    func unrestricted() {
        #expect(IEEE1789.lowRiskLimitPercent(frequencyHz: 1300) == nil)
        #expect(IEEE1789.noObservableEffectLimitPercent(frequencyHz: 1300) == nil)
        #expect(IEEE1789.classify(frequencyHz: 2000, modulationDepthPercent: 90) == .noObservableEffect)
    }

    @Test("Non-positive frequencies have no limit rather than a nonsense one")
    func degenerateInput() {
        #expect(IEEE1789.lowRiskLimitPercent(frequencyHz: 0) == nil)
        #expect(IEEE1789.lowRiskLimitPercent(frequencyHz: -10) == nil)
    }

    @Test("Classification splits the three regions")
    func classification() {
        #expect(IEEE1789.classify(frequencyHz: 100, modulationDepthPercent: 1.0) == .noObservableEffect)
        #expect(IEEE1789.classify(frequencyHz: 100, modulationDepthPercent: 5.0) == .lowRisk)
        #expect(IEEE1789.classify(frequencyHz: 100, modulationDepthPercent: 42.8) == .exceedsLowRisk)
    }

    @Test("A value exactly on a boundary falls to the safer side")
    func boundariesAreInclusiveOfTheSaferRegion() {
        #expect(IEEE1789.classify(frequencyHz: 100, modulationDepthPercent: 3.33) == .noObservableEffect)
        #expect(IEEE1789.classify(frequencyHz: 100, modulationDepthPercent: 8.0) == .lowRisk)
    }

    @Test("Times-over-limit is nil within the limit and a ratio above it")
    func timesOver() {
        #expect(IEEE1789.timesOverLowRiskLimit(frequencyHz: 100, modulationDepthPercent: 16.0) == 2.0)
        #expect(IEEE1789.timesOverLowRiskLimit(frequencyHz: 100, modulationDepthPercent: 4.0) == nil)
        #expect(IEEE1789.timesOverLowRiskLimit(frequencyHz: 2000, modulationDepthPercent: 50) == nil)
    }

    @Test("The sample data's verdicts agree with the classifier")
    func sampleDataIsSelfConsistent() throws {
        // Disagreement would put a badge over a limit sentence that contradicts it.
        for scenario: FlickerScenario in [.tier1ExceedsLimit, .tier1LowRisk, .tier1NoEffect] {
            let result = try FakeFlickerAnalyzer.result(for: scenario)
            guard let frequency = result.frequencyHz,
                  let depth = result.modulationDepthPercent,
                  let verdict = result.verdict else {
                Issue.record("\(scenario) should carry all three Tier 1 fields")
                continue
            }
            #expect(IEEE1789.classify(frequencyHz: frequency, modulationDepthPercent: depth) == verdict)
        }
    }

    @Test("The limit sentence appears only when the tier carries both numbers")
    func limitSentenceFollowsTier() throws {
        let tier1 = try FakeFlickerAnalyzer.result(for: .tier1ExceedsLimit)
        #expect(tier1.limitComparisonSentence?.contains("times stronger than what's generally considered safe") == true)

        let tier2 = try FakeFlickerAnalyzer.result(for: .tier2FrequencyOnly)
        #expect(tier2.limitComparisonSentence == nil)

        let tier3 = try FakeFlickerAnalyzer.result(for: .tier3PresentOnly)
        #expect(tier3.limitComparisonSentence == nil)
    }
}
