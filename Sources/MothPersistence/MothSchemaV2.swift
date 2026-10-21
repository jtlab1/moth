import Foundation
import MeasurementCore
import SwiftData

/// Adds `RoomRecord.copingStrategyRawValues`. Versioned schemas are self-contained
/// snapshots, so every model is redeclared.
public enum MothSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [BuildingRecord.self, RoomRecord.self, RoomMeasurementRecord.self, CalibrationRecord.self]
    }
}

extension MothSchemaV2 {
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

    /// Unknown stored raw values are dropped on load rather than failing.
    @Model
    public final class RoomRecord {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var building: BuildingRecord?
        public var fixtureTypeRaw: String
        public var notes: String
        public var copingStrategyRawValues: [String]
        public var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \RoomMeasurementRecord.room)
        public var measurements: [RoomMeasurementRecord]? = []

        public init(
            id: UUID,
            name: String,
            building: BuildingRecord?,
            fixtureTypeRaw: String,
            notes: String,
            copingStrategyRawValues: [String] = [],
            createdAt: Date
        ) {
            self.id = id
            self.name = name
            self.building = building
            self.fixtureTypeRaw = fixtureTypeRaw
            self.notes = notes
            self.copingStrategyRawValues = copingStrategyRawValues
            self.createdAt = createdAt
        }
    }

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
