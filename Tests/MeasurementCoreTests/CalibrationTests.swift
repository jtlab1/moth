import Foundation
import Testing
@testable import MeasurementCore

@Suite("Calibration")
struct CalibrationTests {

    @Test("Plausible range accepts a realistic readout time")
    func acceptsRealisticValue() {
        #expect(DeviceCalibration.isPlausible(18.5e-6))
        #expect(DeviceCalibration.isPlausible(5e-6))
        #expect(DeviceCalibration.isPlausible(45e-6))
    }

    @Test("Plausible range rejects values off by an order of magnitude")
    func rejectsImplausibleValues() {
        #expect(!DeviceCalibration.isPlausible(900e-6))   // harmonic lock-on
        #expect(!DeviceCalibration.isPlausible(0.1e-6))   // wrong line count
        #expect(!DeviceCalibration.isPlausible(0))
        #expect(!DeviceCalibration.isPlausible(-1e-6))
    }

    @Test("Agreement accepts two solves within tolerance of each other")
    func agreementAcceptsCloseValues() {
        #expect(DeviceCalibration.agree(18.5e-6, 18.5e-6))
        #expect(DeviceCalibration.agree(18.5e-6, 18.9e-6))   // ~2.1% apart
        #expect(DeviceCalibration.agree(20.0e-6, 20.6e-6))   // ~2.9% apart, just inside tolerance
    }

    @Test("Agreement rejects two solves that diverge, even if both are individually plausible")
    func agreementRejectsDivergentValues() {
        #expect(!DeviceCalibration.agree(18.5e-6, 25.0e-6))  // both plausible on their own, but disagree
        #expect(!DeviceCalibration.agree(10e-6, 20e-6))      // one is double the other
        #expect(!DeviceCalibration.agree(0, 18.5e-6))
        #expect(!DeviceCalibration.agree(18.5e-6, -18.5e-6))
    }

    @Test("Fake calibrator solves a plausible value")
    func fakeSolves() async throws {
        let calibrator = FakeDeviceCalibrator(scenario: .succeeds, latency: .zero)
        let solved = try await calibrator.solveLineReadoutTime(
            from: SampleData.frameSequence(), knownFrequencyHz: 100
        )
        #expect(DeviceCalibration.isPlausible(solved))
    }

    @Test("Implausible solutions throw rather than returning a bad number", arguments: [
        CalibrationScenario.implausiblyLarge, .implausiblySmall
    ])
    func implausibleSolutionsThrow(scenario: CalibrationScenario) async {
        let calibrator = FakeDeviceCalibrator(scenario: scenario, latency: .zero)
        await #expect(throws: AnalysisError.self) {
            try await calibrator.solveLineReadoutTime(
                from: SampleData.frameSequence(), knownFrequencyHz: 100
            )
        }
    }

    @Test("Rejection leaves the device at Tier 3")
    func rejectionKeepsTier3() {
        let state = CalibrationState.rejected(solved: 900e-6, attemptedAt: SampleData.now)
        #expect(!state.isCalibrated)
        #expect(state.usableCalibration == nil)

        let uncalibratedProfile = SampleData.tier3Capability
        #expect(uncalibratedProfile.maximumAttainableTier == .tier3)
    }

    @Test("A calibration restored onto different hardware is not applied")
    func foreignDeviceIsNotUsed() {
        let calibration = SampleData.calibration
        #expect(calibration.appliesTo(modelIdentifier: "iPhone17,1"))
        #expect(!calibration.appliesTo(modelIdentifier: "iPhone15,2"))

        let state = CalibrationState.foreignDevice(calibration)
        #expect(!state.isCalibrated)
    }

    @Test("Mains region maps to twice the mains frequency")
    func mainsRegionReference() {
        #expect(MainsRegion.hz50.referenceFlickerFrequencyHz == 100)
        #expect(MainsRegion.hz60.referenceFlickerFrequencyHz == 120)
    }

    @Test("Formatted readout times are human-checkable")
    func formatting() {
        let calibration = SampleData.calibration
        #expect(calibration.formattedLineReadoutTime == "18.50 µs per line")
    }
}

@Suite("Fake analysers")
struct FakeAnalyzerTests {

    @Test("Every flicker scenario either returns a tier-consistent result or throws",
          arguments: FlickerScenario.allCases)
    func scenariosAreConsistent(scenario: FlickerScenario) async {
        let analyzer = FakeFlickerAnalyzer(scenario: scenario, latency: .zero)
        let sequence = SampleData.frameSequence()
        do {
            let result = try await analyzer.analyze(frames: sequence, metadata: sequence.metadata)
            if !result.tier.supportsFrequency { #expect(result.frequencyHz == nil) }
            if !result.tier.supportsModulationDepth { #expect(result.modulationDepthPercent == nil) }
            if !result.tier.supportsVerdict { #expect(result.verdict == nil) }
        } catch is AnalysisError {
            // The failure scenarios exist precisely to be thrown.
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Analysis honours cancellation")
    func cancellation() async {
        let analyzer = FakeFlickerAnalyzer(scenario: .tier1ExceedsLimit, latency: .seconds(10))
        let sequence = SampleData.frameSequence()
        let task = Task {
            try await analyzer.analyze(frames: sequence, metadata: sequence.metadata)
        }
        task.cancel()
        let result = await task.result
        #expect(throws: Error.self) { try result.get() }
    }
}

@Suite("Errors")
struct AnalysisErrorTests {

    @Test("Every error has a user-facing message that is not an error code")
    func messagesExist() {
        let errors: [AnalysisError] = [
            .insufficientSignal(reason: "x"),
            .tooFewFrames(captured: 3, required: 100),
            .captureTooShort(duration: 0.2, required: 2),
            .sensorSaturated,
            .ambiguousFrequency(candidates: [100, 300]),
            .implausibleCalibration(solved: 9e-4, plausible: DeviceCalibration.plausibleLineReadoutRange),
            .unsupportedPixelFormat(0),
            .pixelBufferUnreadable(frameIndex: 0, code: -1),
            .cancelled
        ]
        for error in errors {
            #expect(!error.userFacingMessage.isEmpty)
            #expect(error.errorDescription == error.userFacingMessage)
        }
    }

    @Test("Ambiguous frequency names its candidates so the UI can be specific")
    func ambiguityIsSpecific() {
        let error = AnalysisError.ambiguousFrequency(candidates: [100, 300])
        #expect(error.userFacingMessage.contains("100 Hz"))
        #expect(error.userFacingMessage.contains("300 Hz"))
    }
}

@Suite("Domain model")
struct DomainModelTests {

    @Test("Room summaries sort measurements newest first")
    func newestFirst() {
        let summary = SampleData.summary(for: SampleData.libraryQuietRoom)
        #expect(summary.measurements.count == 3)
        let dates = summary.measurements.map(\.capturedAt)
        #expect(dates == dates.sorted(by: >))
        #expect(summary.latest?.capturedAt == dates.first)
    }

    @Test("Buildings rank their worst room first")
    func buildingRanking() throws {
        let north = try #require(
            SampleData.buildingSummaries.first { $0.building?.id == SampleData.northWing.id }
        )
        #expect(north.rooms.first?.room.id == SampleData.libraryQuietRoom.id)
        #expect(north.worstSeverity == .exceedsLowRisk)
        #expect(north.roomsExceedingLowRisk == 1)
    }

    @Test("Rooms without a building land in a stable Unassigned group")
    func unassignedGroup() throws {
        let group = try #require(SampleData.buildingSummaries.first { $0.building == nil })
        #expect(group.name == "Unassigned")
        #expect(group.id == BuildingSummary.unassignedID)
        #expect(group.rooms.contains { $0.room.id == SampleData.homeOffice.id })
    }

    @Test("Defaults protect the sensory-sensitive user")
    func defaultsAreCalm() {
        let settings = UserSettings.default
        #expect(settings.appearance == .dark) // ships dark; light stays an explicit choice
        #expect(settings.mainsRegion == nil)            // asked, never guessed
    }

    @Test("Mains region infers confidently for unambiguous regions", arguments: [
        ("US", MainsRegion.hz60), ("CA", .hz60), ("MX", .hz60), ("KR", .hz60), ("PH", .hz60),
        ("GB", .hz50), ("FR", .hz50), ("DE", .hz50), ("AU", .hz50), ("IN", .hz50)
    ])
    func mainsRegionInfersConfidentRegions(code: String, expected: MainsRegion) {
        #expect(MainsRegion.inferred(fromRegionCode: code) == expected)
    }

    @Test("Mains region never guesses for known split-grid countries or unknown codes", arguments: [
        "JP", "BR", "PF", "XX", nil
    ])
    func mainsRegionRefusesToGuessSplitGrids(code: String?) {
        #expect(MainsRegion.inferred(fromRegionCode: code) == nil)
    }

    @Test("Measurements round-trip through Codable")
    func measurementCodable() throws {
        let original = SampleData.measurements
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([RoomMeasurement].self, from: data)
        #expect(decoded == original)
    }
}
