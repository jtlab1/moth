import Foundation
import Testing
@testable import MeasurementCore

/// Pinned because it's built on severity, so it must work where depth subtraction can't.
@Suite("Measurement trend")
struct MeasurementTrendTests {

    private func measurement(
        depth: Double? = nil,
        verdict: IEEE1789Verdict? = nil,
        presence: FlickerPresence = .present,
        tier: MeasurementTier = .tier1,
        daysAgo: Int = 0
    ) -> RoomMeasurement {
        RoomMeasurement(
            roomID: UUID(),
            capturedAt: Date().addingTimeInterval(-Double(daysAgo) * 86_400),
            flicker: FlickerResult(
                frequencyHz: tier.supportsFrequency ? 100 : nil,
                modulationDepthPercent: depth,
                verdict: verdict,
                presence: presence,
                confidence: .high,
                tier: tier
            ),
            deviceModelIdentifier: "iPhone17,1",
            appVersion: "1.0"
        )
    }

    @Test("Higher severity than the previous reading is worse")
    func higherSeverityIsWorse() {
        let earlier = measurement(depth: 10, verdict: .lowRisk, daysAgo: 30)
        let later = measurement(depth: 40, verdict: .exceedsLowRisk, daysAgo: 0)
        #expect(later.trend(since: earlier) == .worse)
    }

    @Test("Lower severity than the previous reading is better")
    func lowerSeverityIsBetter() {
        let earlier = measurement(depth: 40, verdict: .exceedsLowRisk, daysAgo: 30)
        let later = measurement(depth: 10, verdict: .lowRisk, daysAgo: 0)
        #expect(later.trend(since: earlier) == .better)
    }

    @Test("Same severity is unchanged, even if the underlying numbers moved a little")
    func sameSeverityIsUnchanged() {
        let earlier = measurement(depth: 30.0, verdict: .exceedsLowRisk, daysAgo: 30)
        let later = measurement(depth: 31.2, verdict: .exceedsLowRisk, daysAgo: 0)
        #expect(later.trend(since: earlier) == .unchanged)
    }

    @Test("Trend still resolves across a tier change, where depth cannot")
    func trendCrossesTiers() {
        // An upgraded phone: no depth on one side, yet severity still orders it.
        let earlier = measurement(presence: .present, tier: .tier3, daysAgo: 60)
        let later = measurement(depth: 2.0, verdict: .noObservableEffect, tier: .tier1, daysAgo: 0)
        #expect(later.trend(since: earlier) == .better)
        #expect(later.modulationDepthChange(since: earlier) == nil)
    }

    @Test("Modulation depth change is the signed difference, only when both sides have one")
    func modulationDepthChangeIsSignedDelta() {
        let earlier = measurement(depth: 28.0, verdict: .exceedsLowRisk, daysAgo: 84)
        let later = measurement(depth: 42.8, verdict: .exceedsLowRisk, daysAgo: 3)
        #expect(abs(later.modulationDepthChange(since: earlier)! - 14.8) < 1e-9)
        #expect(earlier.modulationDepthChange(since: later)! < 0)
    }

    @Test("Modulation depth change is nil when either side lacks depth")
    func modulationDepthChangeRequiresBothSides() {
        let tier2Earlier = measurement(presence: .present, tier: .tier2, daysAgo: 10)
        let tier1Later = measurement(depth: 5.0, verdict: .lowRisk, tier: .tier1, daysAgo: 0)
        #expect(tier1Later.modulationDepthChange(since: tier2Earlier) == nil)
    }
}
