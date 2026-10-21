import Foundation
import MeasurementCore
import SwiftData

public enum MothSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [BuildingRecord.self, RoomRecord.self, RoomMeasurementRecord.self, CalibrationRecord.self]
    }
}

extension MothSchemaV1 {
    @Model
    public final class BuildingRecord {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var notes: String
        public var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \RoomRecord.building)
        public var rooms: [RoomRecord]? = []

        public init(id: UUID, name: String, notes: String, createdAt: Date) {
            self.id = id
            self.name = name
            self.notes = notes
            self.createdAt = createdAt
        }
    }

    /// Raw string so an unknown value from a newer app version degrades to `.unknown`.
    @Model
    public final class RoomRecord {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var building: BuildingRecord?
        public var fixtureTypeRaw: String
        public var notes: String
        public var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \RoomMeasurementRecord.room)
        public var measurements: [RoomMeasurementRecord]? = []

        public init(
            id: UUID,
            name: String,
            building: BuildingRecord?,
            fixtureTypeRaw: String,
            notes: String,
            createdAt: Date
        ) {
            self.id = id
            self.name = name
            self.building = building
            self.fixtureTypeRaw = fixtureTypeRaw
            self.notes = notes
            self.createdAt = createdAt
        }
    }

    /// Top-level, not under a room: calibration belongs to a device.
    @Model
    public final class CalibrationRecord {
        @Attribute(.unique) public var id: UUID
        public var deviceModelIdentifier: String
        public var lineReadoutTime: Double
        public var referenceFrequencyHz: Double
        public var calibratedLineCount: Int
        public var capturedAt: Date

        public init(
            id: UUID,
            deviceModelIdentifier: String,
            lineReadoutTime: Double,
            referenceFrequencyHz: Double,
            calibratedLineCount: Int,
            capturedAt: Date
        ) {
            self.id = id
            self.deviceModelIdentifier = deviceModelIdentifier
            self.lineReadoutTime = lineReadoutTime
            self.referenceFrequencyHz = referenceFrequencyHz
            self.calibratedLineCount = calibratedLineCount
            self.capturedAt = capturedAt
        }
    }

    /// `FlickerResult` as a JSON blob: nothing queries its internals, and a blob can't drift
    /// from its `Codable`. Fields a survey filters on are their own columns.
    @Model
    public final class RoomMeasurementRecord {
        @Attribute(.unique) public var id: UUID
        public var room: RoomRecord?
        public var capturedAt: Date
        public var flickerData: Data
        public var deviceModelIdentifier: String
        public var appVersion: String
        public var lineReadoutTimeUsed: Double?
        public var calibrationID: UUID?
        public var mainsRegionRaw: String?
        public var comfortRating: Int?

        public init(
            id: UUID,
            room: RoomRecord?,
            capturedAt: Date,
            flickerData: Data,
            deviceModelIdentifier: String,
            appVersion: String,
            lineReadoutTimeUsed: Double?,
            calibrationID: UUID?,
            mainsRegionRaw: String?,
            comfortRating: Int?
        ) {
            self.id = id
            self.room = room
            self.capturedAt = capturedAt
            self.flickerData = flickerData
            self.deviceModelIdentifier = deviceModelIdentifier
            self.appVersion = appVersion
            self.lineReadoutTimeUsed = lineReadoutTimeUsed
            self.calibrationID = calibrationID
            self.mainsRegionRaw = mainsRegionRaw
            self.comfortRating = comfortRating
        }
    }
}

/// Every stage so far is additive with defaults, so lightweight migration suffices.
public enum MothMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [MothSchemaV1.self, MothSchemaV2.self, MothSchemaV3.self]
    }
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MothSchemaV1.self, toVersion: MothSchemaV2.self),
            .lightweight(fromVersion: MothSchemaV2.self, toVersion: MothSchemaV3.self)
        ]
    }
}
