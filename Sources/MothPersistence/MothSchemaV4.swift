import Foundation
import MeasurementCore
import SwiftData

/// Adds the capture standard: calibration format signature, response curve and method version;
/// measurement capture conditions. Every new attribute is defaulted or optional so V3 → V4 is
/// lightweight, and migrated calibrations land on version 1, which reads as outdated.
public enum MothSchemaV4: VersionedSchema {
    // V2 and V3 share 2.0.0; 4.0.0 keeps this one unambiguous.
    public static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            BuildingRecord.self,
            RoomRecord.self,
            RoomMeasurementRecord.self,
            CalibrationRecord.self,
            CustomCopingStrategyRecord.self
        ]
    }
}

extension MothSchemaV4 {
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

    @Model
    public final class RoomRecord {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var building: BuildingRecord?
        public var fixtureTypeRaw: String
        public var notes: String
        public var copingStrategyRawValues: [String]
        public var customCopingStrategyIDs: [UUID] = []
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
            customCopingStrategyIDs: [UUID] = [],
            createdAt: Date
        ) {
            self.id = id
            self.name = name
            self.building = building
            self.fixtureTypeRaw = fixtureTypeRaw
            self.notes = notes
            self.copingStrategyRawValues = copingStrategyRawValues
            self.customCopingStrategyIDs = customCopingStrategyIDs
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

        // `CaptureFormatSignature`, flattened. Zero for migrated rows, which match nothing.
        public var formatWidth: Int = 0
        public var formatHeight: Int = 0
        public var formatFrameRate: Double = 0
        /// Raw `OSType`.
        public var formatPixelFormat: Int = 0
        public var formatExposureDuration: Double = 0

        /// Little-endian Float32 × 256; see `ResponseCurve.data`.
        public var responseCurveData: Data?

        /// 1 for everything migrated from V3: solved before the capture standard existed.
        public var calibrationVersion: Int = 1

        public init(
            id: UUID,
            deviceModelIdentifier: String,
            lineReadoutTime: Double,
            referenceFrequencyHz: Double,
            calibratedLineCount: Int,
            capturedAt: Date,
            formatWidth: Int,
            formatHeight: Int,
            formatFrameRate: Double,
            formatPixelFormat: Int,
            formatExposureDuration: Double,
            responseCurveData: Data?,
            calibrationVersion: Int
        ) {
            self.id = id
            self.deviceModelIdentifier = deviceModelIdentifier
            self.lineReadoutTime = lineReadoutTime
            self.referenceFrequencyHz = referenceFrequencyHz
            self.calibratedLineCount = calibratedLineCount
            self.capturedAt = capturedAt
            self.formatWidth = formatWidth
            self.formatHeight = formatHeight
            self.formatFrameRate = formatFrameRate
            self.formatPixelFormat = formatPixelFormat
            self.formatExposureDuration = formatExposureDuration
            self.responseCurveData = responseCurveData
            self.calibrationVersion = calibrationVersion
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

        // Capture conditions, denormalised from `flickerData` so they can be queried; `nil` for
        // measurements taken before the capture standard.
        public var exposureDuration: Double?
        public var iso: Double?
        public var frameRate: Double?
        public var formatWidth: Int?
        public var formatHeight: Int?
        public var droppedFrameCount: Int?
        public var responseCurveApplied: Bool?
        public var analysisVersion: Int?

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
            comfortRating: Int?,
            exposureDuration: Double? = nil,
            iso: Double? = nil,
            frameRate: Double? = nil,
            formatWidth: Int? = nil,
            formatHeight: Int? = nil,
            droppedFrameCount: Int? = nil,
            responseCurveApplied: Bool? = nil,
            analysisVersion: Int? = nil
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
            self.exposureDuration = exposureDuration
            self.iso = iso
            self.frameRate = frameRate
            self.formatWidth = formatWidth
            self.formatHeight = formatHeight
            self.droppedFrameCount = droppedFrameCount
            self.responseCurveApplied = responseCurveApplied
            self.analysisVersion = analysisVersion
        }
    }

    @Model
    public final class CustomCopingStrategyRecord {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var createdAt: Date

        public init(id: UUID, title: String, createdAt: Date) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
        }
    }
}
