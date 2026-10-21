import Foundation
import Testing
@testable import MeasurementCore

@Suite("Tier invariants")
struct TierInvariantTests {

    @Test("Tier 1 keeps every field")
    func tier1KeepsEverything() {
        let result = FlickerResult(
            frequencyHz: 100,
            modulationDepthPercent: 42.8,
            verdict: .exceedsLowRisk,
            presence: .present,
            confidence: .high,
            tier: .tier1
        )
        #expect(result.frequencyHz == 100)
        #expect(result.modulationDepthPercent == 42.8)
        #expect(result.verdict == .exceedsLowRisk)
    }

    @Test("Tier 2 keeps frequency but drops depth and verdict")
    func tier2DropsAmplitudeFields() {
        let result = FlickerResult(
            frequencyHz: 100,
            modulationDepthPercent: 42.8,
            verdict: .exceedsLowRisk,
            presence: .present,
            confidence: .medium,
            tier: .tier2
        )
        #expect(result.frequencyHz == 100)
        #expect(result.modulationDepthPercent == nil)
        #expect(result.verdict == nil)
    }

    @Test("Tier 3 drops every number")
    func tier3DropsEverything() {
        let result = FlickerResult(
            frequencyHz: 100,
            modulationDepthPercent: 42.8,
            verdict: .exceedsLowRisk,
            presence: .present,
            confidence: .low,
            tier: .tier3
        )
        #expect(result.frequencyHz == nil)
        #expect(result.modulationDepthPercent == nil)
        #expect(result.verdict == nil)
        #expect(result.presence == .present)
    }

    @Test("Formatted strings are nil exactly when the underlying value is")
    func formattingRespectsTier() {
        let tier2 = FlickerResult(
            frequencyHz: 100, modulationDepthPercent: 42.8, verdict: .lowRisk,
            presence: .present, confidence: .medium, tier: .tier2
        )
        #expect(tier2.formattedFrequency == "100 Hz")
        #expect(tier2.formattedModulationDepth == nil)
    }

    @Test("Tier ordering runs from least to most capable")
    func tierOrdering() {
        #expect(MeasurementTier.tier3 < MeasurementTier.tier2)
        #expect(MeasurementTier.tier2 < MeasurementTier.tier1)
        #expect(min(MeasurementTier.tier1, .tier3) == .tier3)
    }

    @Test("Capability decides the tier ceiling")
    func capabilityCeiling() {
        func profile(manual: Bool, linear: Bool, calibrated: Bool) -> DeviceCapabilityProfile {
            DeviceCapabilityProfile(
                modelIdentifier: "iPhone17,1",
                supportsManualExposure: manual,
                exposureDurationRange: 1e-5...0.3,
                isoRange: 34...3072,
                maximumFrameRate: 240,
                providesLinearCapture: linear,
                isCalibrated: calibrated
            )
        }
        #expect(profile(manual: true, linear: true, calibrated: true).maximumAttainableTier == .tier1)
        #expect(profile(manual: true, linear: false, calibrated: true).maximumAttainableTier == .tier2)
        #expect(profile(manual: false, linear: true, calibrated: true).maximumAttainableTier == .tier2)
        #expect(profile(manual: true, linear: true, calibrated: false).maximumAttainableTier == .tier3)
        #expect(profile(manual: false, linear: false, calibrated: false).maximumAttainableTier == .tier3)
    }

    @Test("Clamping lowers an over-optimistic tier and leaves a conservative one alone")
    func clampingIsOneDirectional() {
        let tier2Device = SampleData.tier2Capability
        #expect(tier2Device.clampedTier(.tier1) == .tier2)
        #expect(tier2Device.clampedTier(.tier3) == .tier3)

        let tier1Device = SampleData.tier1Capability
        #expect(tier1Device.clampedTier(.tier1) == .tier1)
        #expect(tier1Device.clampedTier(.tier2) == .tier2)
    }
}

@Suite("Severity ordering")
struct SeverityTests {

    @Test("Worst-first ordering puts over-the-limit rooms at the top")
    func ordering() {
        let sorted: [FlickerSeverity] = [.lowRisk, .exceedsLowRisk, .none, .detectedUnrated, .unknown]
            .sorted(by: >)
        #expect(sorted == [.exceedsLowRisk, .detectedUnrated, .lowRisk, .none, .unknown])
    }

    @Test("Ungraded flicker outranks a graded low-risk result")
    func ungradedOutranksLowRisk() {
        // Pinned judgement call: "we don't know" outranks "we checked and it's fine".
        #expect(FlickerSeverity.detectedUnrated > FlickerSeverity.lowRisk)
    }

    @Test("Severity is derived consistently from verdict and presence")
    func derivation() throws {
        let tier1Bad = try FakeFlickerAnalyzer.result(for: .tier1ExceedsLimit)
        #expect(tier1Bad.severity == .exceedsLowRisk)

        let tier2 = try FakeFlickerAnalyzer.result(for: .tier2FrequencyOnly)
        #expect(tier2.severity == .detectedUnrated)

        let tier3Present = try FakeFlickerAnalyzer.result(for: .tier3PresentOnly)
        #expect(tier3Present.severity == .detectedUnrated)

        let clean = try FakeFlickerAnalyzer.result(for: .tier1NoFlicker)
        #expect(clean.severity == .none)
    }

    @Test("A room with no measurements is unknown, not safe")
    func unmeasuredRoomIsNotSafe() {
        let summary = RoomSummary(room: SampleData.lab3, building: nil, measurements: [])
        #expect(summary.severity == .unknown)
        #expect(summary.severity != .none)
    }
}
