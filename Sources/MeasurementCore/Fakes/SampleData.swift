#if DEBUG
import CoreVideo
import Foundation

/// Fixed UUIDs and dates so previews are stable and snapshot tests don't fail at midnight.
public enum SampleData {
    // MARK: - Fixed clock

    /// 2026-03-04 09:00 UTC.
    public static let now = Date(timeIntervalSince1970: 1_772_614_800)

    private static func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    // MARK: - Buildings

    public static let northWing = Building(
        id: id(1),
        name: "North Wing",
        notes: "1970s build, original fluorescent fittings on floors 1–2.",
        createdAt: daysAgo(90)
    )

    public static let scienceBlock = Building(
        id: id(2),
        name: "Science Block",
        notes: "Refitted 2023.",
        createdAt: daysAgo(60)
    )

    public static let buildings = [northWing, scienceBlock]

    // MARK: - Rooms

    public static let libraryQuietRoom = Room(
        id: id(10),
        name: "Library Quiet Room",
        buildingID: northWing.id,
        fixtureType: .fluorescentTube,
        notes: "Worst by the window end. Two students have complained about headaches.",
        createdAt: daysAgo(88)
    )

    public static let corridor2F = Room(
        id: id(11),
        name: "Corridor 2F",
        buildingID: northWing.id,
        fixtureType: .ledPanel,
        notes: "",
        createdAt: daysAgo(80)
    )

    public static let staffRoom = Room(
        id: id(12),
        name: "Staff Room",
        buildingID: northWing.id,
        fixtureType: .mixed,
        notes: "Ceiling LEDs plus two desk lamps.",
        createdAt: daysAgo(40)
    )

    public static let lab3 = Room(
        id: id(13),
        name: "Lab 3",
        buildingID: scienceBlock.id,
        fixtureType: .ledPanel,
        notes: "New panels, seem fine.",
        createdAt: daysAgo(30)
    )

    public static let atrium = Room(
        id: id(14),
        name: "Atrium",
        buildingID: scienceBlock.id,
        fixtureType: .daylightOnly,
        notes: "Measured mid-morning, blinds open.",
        createdAt: daysAgo(20)
    )

    public static let homeOffice = Room(
        id: id(15),
        name: "Home Office",
        buildingID: nil,
        fixtureType: .unknown,
        notes: "",
        createdAt: daysAgo(5)
    )

    public static let rooms = [libraryQuietRoom, corridor2F, staffRoom, lab3, atrium, homeOffice]

    // MARK: - Measurements

    private static func measurement(
        _ n: Int,
        room: Room,
        daysAgo days: Int,
        flicker: FlickerResult,
        comfortRating: Int? = nil
    ) -> RoomMeasurement {
        RoomMeasurement(
            id: id(n),
            roomID: room.id,
            capturedAt: daysAgo(days),
            flicker: flicker,
            deviceModelIdentifier: "iPhone17,1",
            appVersion: "1.0",
            lineReadoutTimeUsed: flicker.tier == .tier3 ? nil : 18.5e-6,
            comfortRating: comfortRating
        )
    }

    /// Getting worse over time: the case the Room Detail history section exists to show.
    public static let measurements: [RoomMeasurement] = [
        measurement(
            100, room: libraryQuietRoom, daysAgo: 84,
            flicker: FlickerResult(
                frequencyHz: 100, modulationDepthPercent: 28.0, verdict: .exceedsLowRisk,
                presence: .present, confidence: .high, tier: .tier1, analyzedAt: daysAgo(84)
            ),
            comfortRating: 3
        ),
        measurement(
            101, room: libraryQuietRoom, daysAgo: 42,
            flicker: FlickerResult(
                frequencyHz: 100, modulationDepthPercent: 36.5, verdict: .exceedsLowRisk,
                presence: .present, confidence: .high, tier: .tier1, analyzedAt: daysAgo(42)
            ),
            comfortRating: 2
        ),
        measurement(
            102, room: libraryQuietRoom, daysAgo: 3,
            flicker: FlickerResult(
                frequencyHz: 100, modulationDepthPercent: 42.8, verdict: .exceedsLowRisk,
                presence: .present, confidence: .high, tier: .tier1, analyzedAt: daysAgo(3)
            ),
            comfortRating: 1
        ),
        measurement(
            110, room: corridor2F, daysAgo: 12,
            flicker: FlickerResult(
                frequencyHz: 120, modulationDepthPercent: 7.2, verdict: .lowRisk,
                presence: .present, confidence: .high, tier: .tier1, analyzedAt: daysAgo(12)
            )
        ),
        measurement(
            120, room: staffRoom, daysAgo: 9,
            flicker: FlickerResult(
                frequencyHz: 100, presence: .present, confidence: .medium,
                tier: .tier2, analyzedAt: daysAgo(9)
            )
        ),
        measurement(
            130, room: lab3, daysAgo: 7,
            flicker: FlickerResult(
                frequencyHz: 3_000, modulationDepthPercent: 1.4, verdict: .noObservableEffect,
                presence: .present, confidence: .high, tier: .tier1, analyzedAt: daysAgo(7)
            )
        ),
        measurement(
            140, room: atrium, daysAgo: 6,
            flicker: FlickerResult(
                presence: .absent, confidence: .high, tier: .tier1, analyzedAt: daysAgo(6)
            ),
            comfortRating: 5
        ),
        measurement(
            150, room: homeOffice, daysAgo: 4,
            flicker: FlickerResult(
                presence: .present, confidence: .medium, tier: .tier3, analyzedAt: daysAgo(4)
            )
        )
    ]

    // MARK: - Assembled summaries

    public static func summary(for room: Room) -> RoomSummary {
        RoomSummary(
            room: room,
            building: buildings.first { $0.id == room.buildingID },
            measurements: measurements.filter { $0.roomID == room.id }
        )
    }

    public static var roomSummaries: [RoomSummary] {
        rooms.map(summary(for:))
    }

    public static var buildingSummaries: [BuildingSummary] {
        let grouped = Dictionary(grouping: roomSummaries) { $0.room.buildingID }
        return grouped
            .map { buildingID, rooms in
                BuildingSummary(
                    building: buildings.first { $0.id == buildingID },
                    rooms: rooms
                )
            }
            .sorted { lhs, rhs in
                if lhs.worstSeverity != rhs.worstSeverity { return lhs.worstSeverity > rhs.worstSeverity }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Calibration and capability

    public static let calibration = DeviceCalibration(
        id: id(200),
        deviceModelIdentifier: "iPhone17,1",
        lineReadoutTime: 18.5e-6,
        referenceFrequencyHz: 100,
        calibratedLineCount: 1080,
        capturedAt: daysAgo(85)
    )

    public static let tier1Capability = DeviceCapabilityProfile(
        modelIdentifier: "iPhone17,1",
        supportsManualExposure: true,
        exposureDurationRange: 1.0 / 8000.0...1.0 / 3.0,
        isoRange: 34...3072,
        maximumFrameRate: 240,
        providesLinearCapture: true,
        isCalibrated: true
    )

    public static let tier2Capability = DeviceCapabilityProfile(
        modelIdentifier: "iPhone12,1",
        supportsManualExposure: true,
        exposureDurationRange: 1.0 / 8000.0...1.0 / 3.0,
        isoRange: 32...2016,
        maximumFrameRate: 120,
        providesLinearCapture: false,
        isCalibrated: true
    )

    public static let tier3Capability = DeviceCapabilityProfile(
        modelIdentifier: "iPhone12,1",
        supportsManualExposure: true,
        exposureDurationRange: 1.0 / 8000.0...1.0 / 3.0,
        isoRange: 32...2016,
        maximumFrameRate: 120,
        providesLinearCapture: false,
        isCalibrated: false
    )

    // MARK: - Synthetic capture

    /// Blank frames: a fake flicker signal is guaranteed to make a real analyser look like it works.
    public static func captureMetadata(
        frameCount: Int = 120,
        capability: DeviceCapabilityProfile = tier1Capability,
        exposureMode: ExposureMode = .manual,
        lineReadoutTime: TimeInterval? = 18.5e-6,
        dimensions: FrameDimensions = FrameDimensions(width: 1920, height: 1080),
        frameRate: Double = 120
    ) -> CaptureMetadata {
        let frames = (0..<frameCount).map { index in
            FrameMetadata(
                index: index,
                presentationTime: Double(index) / frameRate,
                exposureDuration: 1.0 / 2000.0,
                iso: 400,
                exposureMode: exposureMode,
                lensAperture: 1.78
            )
        }
        return CaptureMetadata(
            dimensions: dimensions,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nominalFrameRate: frameRate,
            frames: frames,
            lineReadoutTime: lineReadoutTime,
            deviceCapability: capability,
            startedAt: now
        )
    }

    /// For plumbing (counts, lifetimes, plane access), not analysis.
    public static func frameSequence(
        frameCount: Int = 8,
        dimensions: FrameDimensions = FrameDimensions(width: 64, height: 48)
    ) -> FrameSequence {
        var buffers: [CVPixelBuffer] = []
        for _ in 0..<frameCount {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                dimensions.width,
                dimensions.height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &buffer
            )
            precondition(status == kCVReturnSuccess, "failed to create sample pixel buffer")
            buffers.append(buffer!)
        }
        return FrameSequence(
            buffers: buffers,
            metadata: captureMetadata(frameCount: frameCount, dimensions: dimensions)
        )
    }
}
#endif
