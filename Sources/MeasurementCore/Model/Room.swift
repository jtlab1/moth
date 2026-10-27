import Foundation

// Plain Sendable structs instead of `@Model` classes so results move freely from analysis to SwiftUI.

/// Flat, no floors or wings: the name is the grouping key people already use.
public struct Building: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var notes: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
    }
}

public struct Room: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var name: String

    /// Optional so saving a first measurement never requires naming a building.
    public var buildingID: UUID?

    /// Declared by the user, never inferred; see `FixtureType`.
    public var fixtureType: FixtureType
    public var notes: String

    /// A personal checklist, not guidance the app asserts.
    public var copingStrategies: Set<CopingStrategy>
    public var customCopingStrategyIDs: Set<UUID>

    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        buildingID: UUID? = nil,
        fixtureType: FixtureType = .unknown,
        notes: String = "",
        copingStrategies: Set<CopingStrategy> = [],
        customCopingStrategyIDs: Set<UUID> = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.buildingID = buildingID
        self.fixtureType = fixtureType
        self.notes = notes
        self.copingStrategies = copingStrategies
        self.customCopingStrategyIDs = customCopingStrategyIDs
        self.createdAt = createdAt
    }
}

/// Not `Measurement`, which collides with Foundation's `Measurement<UnitType>`.
public struct RoomMeasurement: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let roomID: UUID
    public let capturedAt: Date
    public let flicker: FlickerResult
    public let deviceModelIdentifier: String

    /// So an old record survives a change in analysis.
    public let appVersion: String

    /// Snapshotted so re-calibrating never rewrites the meaning of past measurements.
    public let lineReadoutTimeUsed: TimeInterval?
    public let calibrationID: UUID?

    /// Snapshotted so changing the setting later never rewrites an old frequency's meaning.
    public let mainsRegion: MainsRegion?

    /// Asked, never inferred: the point is to learn whether comfort tracks the measurements.
    public let comfortRating: Int?

    public init(
        id: UUID = UUID(),
        roomID: UUID,
        capturedAt: Date = Date(),
        flicker: FlickerResult,
        deviceModelIdentifier: String,
        appVersion: String,
        lineReadoutTimeUsed: TimeInterval? = nil,
        calibrationID: UUID? = nil,
        mainsRegion: MainsRegion? = nil,
        comfortRating: Int? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.capturedAt = capturedAt
        self.flicker = flicker
        self.deviceModelIdentifier = deviceModelIdentifier
        self.appVersion = appVersion
        self.lineReadoutTimeUsed = lineReadoutTimeUsed
        self.calibrationID = calibrationID
        self.mainsRegion = mainsRegion
        self.comfortRating = comfortRating.map { min(max($0, RoomMeasurement.comfortRatingRange.lowerBound), RoomMeasurement.comfortRatingRange.upperBound) }
    }

    public static let comfortRatingRange: ClosedRange<Int> = 1...5
}

extension RoomMeasurement {
    public var severity: FlickerSeverity { flicker.severity }
}

/// On severity, not depth, so readings from different tiers and hardware still compare.
public enum MeasurementTrend: Sendable, Equatable {
    case worse
    case unchanged
    case better

    public var title: String {
        switch self {
        case .worse: return "Worse than last reading"
        case .unchanged: return "Same as last reading"
        case .better: return "Better than last reading"
        }
    }

    public var iconName: String {
        switch self {
        case .worse: return "arrow.up.circle.fill"
        case .unchanged: return "equal.circle.fill"
        case .better: return "arrow.down.circle.fill"
        }
    }
}

extension RoomMeasurement {
    public func trend(since previous: RoomMeasurement) -> MeasurementTrend {
        if severity > previous.severity { return .worse }
        if severity < previous.severity { return .better }
        return .unchanged
    }

    /// Tier 1 pairs only; other tiers get just `trend(since:)`.
    public func modulationDepthChange(since previous: RoomMeasurement) -> Double? {
        guard let depth = flicker.modulationDepthPercent,
              let previousDepth = previous.flicker.modulationDepthPercent
        else { return nil }
        return depth - previousDepth
    }
}

/// One place that decides which measurement is latest, so screens can't disagree.
public struct RoomSummary: Sendable, Hashable, Identifiable {
    public let room: Room
    public let building: Building?

    /// Newest first.
    public let measurements: [RoomMeasurement]

    public var id: UUID { room.id }

    public init(room: Room, building: Building?, measurements: [RoomMeasurement]) {
        self.room = room
        self.building = building
        self.measurements = measurements.sorted { $0.capturedAt > $1.capturedAt }
    }

    public var latest: RoomMeasurement? { measurements.first }

    /// No measurements sorts as `.unknown`: an unmeasured room is not a safe room.
    public var severity: FlickerSeverity { latest?.severity ?? .unknown }

    public var buildingName: String { building?.name ?? "Unassigned" }

}

/// Ranked worst-first.
public struct BuildingSummary: Sendable, Hashable, Identifiable {
    public let building: Building?
    public let rooms: [RoomSummary]

    public var id: UUID { building?.id ?? Self.unassignedID }

    /// Fixed so the unassigned group keeps its identity and doesn't animate in and out.
    public static let unassignedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public init(building: Building?, rooms: [RoomSummary]) {
        self.building = building
        self.rooms = rooms.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.room.name.localizedStandardCompare(rhs.room.name) == .orderedAscending
        }
    }

    public var name: String { building?.name ?? "Unassigned" }

    public var worstSeverity: FlickerSeverity {
        rooms.map(\.severity).max() ?? .unknown
    }

    public var roomsExceedingLowRisk: Int {
        rooms.filter { $0.severity == .exceedsLowRisk }.count
    }
}
