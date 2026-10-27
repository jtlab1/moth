import Foundation
import MeasurementCore
import Observation
import SwiftData

/// Keeps SwiftData's opaque errors out of callers' matching.
public enum MothStoreError: Error, LocalizedError {
    case flickerResultUndecodable
    case roomNotFound
    case buildingNotFound
    case customCopingStrategyTitleEmpty
    case nameEmpty
    case roomNameTaken
    case buildingNameTaken

    public var errorDescription: String? {
        switch self {
        case .flickerResultUndecodable:
            return "A stored measurement's data was corrupted and could not be read."
        case .roomNotFound:
            return "That room no longer exists."
        case .buildingNotFound:
            return "That building no longer exists."
        case .customCopingStrategyTitleEmpty:
            return "Give the strategy a name first."
        case .nameEmpty:
            return "The name can't be empty."
        case .roomNameTaken:
            return "Another room already has that name."
        case .buildingNameTaken:
            return "Another building already has that name."
        }
    }
}

/// The one place domain structs map to `@Model` records.
/// `@MainActor` because `ModelContext` isn't `Sendable` and every caller is SwiftUI.
@MainActor
@Observable
public final class MothStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Every read touches this and every write bumps it, so `@Observable` re-renders after writes.
    private var changeToken = 0

    public init(container: ModelContainer) {
        self.container = container
    }

    public static func makeDefault() throws -> MothStore {
        try makeDefault(storeURL: Self.defaultStoreURL())
    }

    public static func makeInMemory() throws -> MothStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(versionedSchema: MothSchemaV4.self),
            migrationPlan: MothMigrationPlan.self,
            configurations: configuration
        )
        return MothStore(container: container)
    }

    /// Takes a URL so tests stay off the real store. Replaces an unopenable store with a fresh one,
    /// since falling back to in-memory would wipe data every launch.
    static func makeDefault(storeURL: URL) throws -> MothStore {
        do {
            return try MothStore(container: Self.makeOnDiskContainer(at: storeURL))
        } catch {
            try? Self.removeStoreFiles(at: storeURL)
            return try MothStore(container: Self.makeOnDiskContainer(at: storeURL))
        }
    }

    private static func makeOnDiskContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: MothSchemaV4.self),
            migrationPlan: MothMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    private static func defaultStoreURL() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return supportDirectory.appending(path: "Moth.store")
    }

    /// All three files, or SwiftData reopens the broken WAL and fails again.
    private static func removeStoreFiles(at url: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }

    // MARK: - Reads

    public var buildings: [Building] {
        _ = changeToken
        return fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt).map(Self.domain)
    }

    public var rooms: [Room] {
        _ = changeToken
        return fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).map(Self.domain)
    }

    /// Undecodable records are dropped rather than crashing the list.
    public var measurements: [RoomMeasurement] {
        _ = changeToken
        return fetchAll(MothSchemaV4.RoomMeasurementRecord.self, sortBy: \.capturedAt).compactMap(Self.domain)
    }

    /// Oldest first, so a new one lands at the end instead of reshuffling pills.
    public var customCopingStrategies: [CustomCopingStrategy] {
        _ = changeToken
        return fetchAll(MothSchemaV4.CustomCopingStrategyRecord.self, sortBy: \.createdAt).map(Self.domain)
    }

    public var calibrations: [DeviceCalibration] {
        _ = changeToken
        return fetchAll(MothSchemaV4.CalibrationRecord.self, sortBy: \.capturedAt).map(Self.domain)
    }

    /// Whether a calibration can be used for `format`: `.calibrated` for a current, matching one,
    /// `.outdated` if this model has calibrations but none apply.
    public func calibrationState(
        forDeviceModelIdentifier modelIdentifier: String,
        format: CaptureFormatSignature
    ) -> CalibrationState {
        let all = calibrations
        guard let latest = all.max(by: { $0.capturedAt < $1.capturedAt }) else {
            return .uncalibrated
        }
        let sameModel = all.filter { $0.deviceModelIdentifier == modelIdentifier }
        guard let latestSameModel = sameModel.max(by: { $0.capturedAt < $1.capturedAt }) else {
            return .foreignDevice(latest)
        }
        guard let applicable = sameModel
            .filter({ $0.appliesTo(modelIdentifier: modelIdentifier, format: format) })
            .max(by: { $0.capturedAt < $1.capturedAt })
        else {
            return .outdated(latestSameModel)
        }
        return .calibrated(applicable)
    }

    /// For callers that don't know the format yet (first-run gate, Settings).
    /// Checks version but not format; the capture layer re-checks format before using it.
    public func calibrationState(forDeviceModelIdentifier modelIdentifier: String) -> CalibrationState {
        let all = calibrations
        guard let latest = all.max(by: { $0.capturedAt < $1.capturedAt }) else {
            return .uncalibrated
        }
        let sameModel = all.filter { $0.deviceModelIdentifier == modelIdentifier }
        guard let latestSameModel = sameModel.max(by: { $0.capturedAt < $1.capturedAt }) else {
            return .foreignDevice(latest)
        }
        guard let current = sameModel.filter(\.isCurrentVersion).max(by: { $0.capturedAt < $1.capturedAt }) else {
            return .outdated(latestSameModel)
        }
        return .calibrated(current)
    }

    // MARK: - Writes

    /// Keeps older calibrations: the history shows whether readout time drifts.
    public func addCalibration(_ calibration: DeviceCalibration) throws {
        context.insert(
            MothSchemaV4.CalibrationRecord(
                id: calibration.id,
                deviceModelIdentifier: calibration.deviceModelIdentifier,
                lineReadoutTime: calibration.lineReadoutTime,
                referenceFrequencyHz: calibration.referenceFrequencyHz,
                calibratedLineCount: calibration.calibratedLineCount,
                capturedAt: calibration.capturedAt,
                formatWidth: calibration.format.width,
                formatHeight: calibration.format.height,
                formatFrameRate: calibration.format.frameRate,
                formatPixelFormat: Int(calibration.format.pixelFormat),
                formatExposureDuration: calibration.format.exposureDuration,
                responseCurveData: calibration.responseCurve?.data,
                calibrationVersion: calibration.calibrationVersion
            )
        )
        try context.save()
        changeToken += 1
    }

    /// Finds the room by case-insensitive name or creates it.
    @discardableResult
    public func saveMeasurement(
        _ measurement: RoomMeasurement,
        roomName: String,
        buildingID: UUID? = nil
    ) throws -> Room {
        let trimmedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingRooms = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt)
        let roomRecord: MothSchemaV4.RoomRecord
        if let match = existingRooms.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            roomRecord = match
        } else {
            var buildingRecord: MothSchemaV4.BuildingRecord?
            if let buildingID {
                buildingRecord = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt)
                    .first { $0.id == buildingID }
            }
            roomRecord = MothSchemaV4.RoomRecord(
                id: UUID(),
                name: trimmedName,
                building: buildingRecord,
                fixtureTypeRaw: FixtureType.unknown.rawValue,
                notes: "",
                createdAt: Date()
            )
            context.insert(roomRecord)
        }

        let flicker = measurement.flicker
        let conditions = flicker.conditions
        let flickerData = try JSONEncoder().encode(flicker)
        let measurementRecord = MothSchemaV4.RoomMeasurementRecord(
            id: measurement.id,
            room: roomRecord,
            capturedAt: measurement.capturedAt,
            flickerData: flickerData,
            deviceModelIdentifier: measurement.deviceModelIdentifier,
            appVersion: measurement.appVersion,
            lineReadoutTimeUsed: measurement.lineReadoutTimeUsed,
            calibrationID: measurement.calibrationID,
            mainsRegionRaw: measurement.mainsRegion?.rawValue,
            comfortRating: measurement.comfortRating,
            exposureDuration: conditions?.exposureDuration,
            iso: conditions.map { Double($0.iso) },
            frameRate: conditions?.frameRate,
            formatWidth: conditions?.formatSignature.width,
            formatHeight: conditions?.formatSignature.height,
            droppedFrameCount: conditions?.droppedFrameCount,
            responseCurveApplied: flicker.responseCurveApplied,
            analysisVersion: flicker.analysisVersion
        )
        context.insert(measurementRecord)
        try context.save()
        changeToken += 1
        return Self.domain(roomRecord)
    }

    /// Find-or-create by case-insensitive name, so an existing name navigates rather than duplicates.
    @discardableResult
    public func createRoom(name: String, buildingID: UUID? = nil) throws -> Room {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingRooms = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt)
        if let match = existingRooms.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return Self.domain(match)
        }

        var buildingRecord: MothSchemaV4.BuildingRecord?
        if let buildingID {
            buildingRecord = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt)
                .first { $0.id == buildingID }
        }
        let roomRecord = MothSchemaV4.RoomRecord(
            id: UUID(),
            name: trimmedName,
            building: buildingRecord,
            fixtureTypeRaw: FixtureType.unknown.rawValue,
            notes: "",
            createdAt: Date()
        )
        context.insert(roomRecord)
        try context.save()
        changeToken += 1
        return Self.domain(roomRecord)
    }

    /// Find-or-create by case-insensitive name.
    @discardableResult
    public func createBuilding(name: String) throws -> Building {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt)
        if let match = existing.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return Self.domain(match)
        }
        let record = MothSchemaV4.BuildingRecord(id: UUID(), name: trimmedName, notes: "", createdAt: Date())
        context.insert(record)
        try context.save()
        changeToken += 1
        return Self.domain(record)
    }

    public func updateRoomBuilding(roomID: UUID, buildingID: UUID?) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == roomID }) else {
            throw MothStoreError.roomNotFound
        }
        if let buildingID {
            guard let buildingRecord = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt)
                .first(where: { $0.id == buildingID })
            else {
                throw MothStoreError.buildingNotFound
            }
            record.building = buildingRecord
        } else {
            record.building = nil
        }
        try context.save()
        changeToken += 1
    }

    /// Names stay unique ignoring case, since `saveMeasurement` looks rooms up by name.
    public func renameRoom(id: UUID, to name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MothStoreError.nameEmpty }
        let records = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt)
        guard let record = records.first(where: { $0.id == id }) else {
            throw MothStoreError.roomNotFound
        }
        guard !records.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            throw MothStoreError.roomNameTaken
        }
        record.name = trimmedName
        try context.save()
        changeToken += 1
    }

    public func renameBuilding(id: UUID, to name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MothStoreError.nameEmpty }
        let records = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt)
        guard let record = records.first(where: { $0.id == id }) else {
            throw MothStoreError.buildingNotFound
        }
        guard !records.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            throw MothStoreError.buildingNameTaken
        }
        record.name = trimmedName
        try context.save()
        changeToken += 1
    }

    /// Irreversible and takes the room's measurements with it; the caller confirms with the user.
    public func deleteRoom(id: UUID) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == id }) else {
            return
        }
        context.delete(record)
        try context.save()
        changeToken += 1
    }

    /// Its rooms become unassigned instead of cascading, since deleting a grouping shouldn't erase readings.
    public func deleteBuilding(id: UUID) throws {
        guard let record = fetchAll(MothSchemaV4.BuildingRecord.self, sortBy: \.createdAt).first(where: { $0.id == id }) else {
            return
        }
        for room in fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt) where room.building?.id == id {
            room.building = nil
        }
        context.delete(record)
        try context.save()
        changeToken += 1
    }

    public func updateFixtureType(roomID: UUID, fixtureType: FixtureType) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == roomID }) else {
            throw MothStoreError.roomNotFound
        }
        record.fixtureTypeRaw = fixtureType.rawValue
        try context.save()
        changeToken += 1
    }

    public func updateNotes(roomID: UUID, notes: String) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == roomID }) else {
            throw MothStoreError.roomNotFound
        }
        record.notes = notes
        try context.save()
        changeToken += 1
    }

    public func updateCopingStrategies(roomID: UUID, strategies: Set<CopingStrategy>) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == roomID }) else {
            throw MothStoreError.roomNotFound
        }
        record.copingStrategyRawValues = strategies.map(\.rawValue)
        try context.save()
        changeToken += 1
    }

    /// Find-or-create by case-insensitive title.
    @discardableResult
    public func addCustomCopingStrategy(title: String) throws -> CustomCopingStrategy {
        guard let normalized = CustomCopingStrategy.normalizedTitle(title) else {
            throw MothStoreError.customCopingStrategyTitleEmpty
        }
        let existing = fetchAll(MothSchemaV4.CustomCopingStrategyRecord.self, sortBy: \.createdAt)
        if let match = existing.first(where: { $0.title.localizedCaseInsensitiveCompare(normalized) == .orderedSame }) {
            return Self.domain(match)
        }
        let record = MothSchemaV4.CustomCopingStrategyRecord(id: UUID(), title: normalized, createdAt: Date())
        context.insert(record)
        try context.save()
        changeToken += 1
        return Self.domain(record)
    }

    public func updateCustomCopingStrategies(roomID: UUID, strategyIDs: Set<UUID>) throws {
        guard let record = fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt).first(where: { $0.id == roomID }) else {
            throw MothStoreError.roomNotFound
        }
        record.customCopingStrategyIDs = Array(strategyIDs)
        try context.save()
        changeToken += 1
    }

    /// Also unchecks it in every room, so nothing points at a missing id.
    public func deleteCustomCopingStrategy(id: UUID) throws {
        guard let record = fetchAll(MothSchemaV4.CustomCopingStrategyRecord.self, sortBy: \.createdAt)
            .first(where: { $0.id == id })
        else {
            return
        }
        for room in fetchAll(MothSchemaV4.RoomRecord.self, sortBy: \.createdAt) where room.customCopingStrategyIDs.contains(id) {
            room.customCopingStrategyIDs.removeAll { $0 == id }
        }
        context.delete(record)
        try context.save()
        changeToken += 1
    }

    /// Irreversible; the caller confirms with the user.
    public func wipeAll() throws {
        try context.delete(model: MothSchemaV4.RoomMeasurementRecord.self)
        try context.delete(model: MothSchemaV4.RoomRecord.self)
        try context.delete(model: MothSchemaV4.BuildingRecord.self)
        try context.delete(model: MothSchemaV4.CalibrationRecord.self)
        try context.delete(model: MothSchemaV4.CustomCopingStrategyRecord.self)
        try context.save()
        changeToken += 1
    }

    /// Irreversible and scoped to one device model; the caller confirms with the user.
    public func resetCalibration(forDeviceModelIdentifier modelIdentifier: String) throws {
        let records = fetchAll(MothSchemaV4.CalibrationRecord.self, sortBy: \.capturedAt)
            .filter { $0.deviceModelIdentifier == modelIdentifier }
        guard !records.isEmpty else { return }
        for record in records {
            context.delete(record)
        }
        try context.save()
        changeToken += 1
    }

    // MARK: - Fetching

    private func fetchAll<T: PersistentModel, V: Comparable>(
        _ type: T.Type,
        sortBy keyPath: KeyPath<T, V> & Sendable
    ) -> [T] {
        let descriptor = FetchDescriptor<T>(sortBy: [SortDescriptor(keyPath)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Domain mapping

    private static func domain(_ record: MothSchemaV4.BuildingRecord) -> Building {
        Building(id: record.id, name: record.name, notes: record.notes, createdAt: record.createdAt)
    }

    private static func domain(_ record: MothSchemaV4.RoomRecord) -> Room {
        Room(
            id: record.id,
            name: record.name,
            buildingID: record.building?.id,
            fixtureType: FixtureType(rawValue: record.fixtureTypeRaw) ?? .unknown,
            notes: record.notes,
            // Unknown raw values from a newer app version are dropped, not fatal.
            copingStrategies: Set(record.copingStrategyRawValues.compactMap(CopingStrategy.init(rawValue:))),
            customCopingStrategyIDs: Set(record.customCopingStrategyIDs),
            createdAt: record.createdAt
        )
    }

    private static func domain(_ record: MothSchemaV4.CustomCopingStrategyRecord) -> CustomCopingStrategy {
        CustomCopingStrategy(id: record.id, title: record.title, createdAt: record.createdAt)
    }

    /// A curve that no longer validates gets dropped, not fatal; frequency still works and Tier 1 stays off.
    private static func domain(_ record: MothSchemaV4.CalibrationRecord) -> DeviceCalibration {
        DeviceCalibration(
            id: record.id,
            deviceModelIdentifier: record.deviceModelIdentifier,
            lineReadoutTime: record.lineReadoutTime,
            referenceFrequencyHz: record.referenceFrequencyHz,
            calibratedLineCount: record.calibratedLineCount,
            format: CaptureFormatSignature(
                width: record.formatWidth,
                height: record.formatHeight,
                frameRate: record.formatFrameRate,
                pixelFormat: UInt32(truncatingIfNeeded: record.formatPixelFormat),
                exposureDuration: record.formatExposureDuration
            ),
            responseCurve: record.responseCurveData.flatMap { try? ResponseCurve(data: $0) },
            calibrationVersion: record.calibrationVersion,
            capturedAt: record.capturedAt
        )
    }

    private static func domain(_ record: MothSchemaV4.RoomMeasurementRecord) -> RoomMeasurement? {
        guard let flicker = try? JSONDecoder().decode(FlickerResult.self, from: record.flickerData),
              let roomID = record.room?.id
        else {
            return nil
        }
        return RoomMeasurement(
            id: record.id,
            roomID: roomID,
            capturedAt: record.capturedAt,
            flicker: flicker,
            deviceModelIdentifier: record.deviceModelIdentifier,
            appVersion: record.appVersion,
            lineReadoutTimeUsed: record.lineReadoutTimeUsed,
            calibrationID: record.calibrationID,
            mainsRegion: record.mainsRegionRaw.flatMap(MainsRegion.init(rawValue:)),
            comfortRating: record.comfortRating
        )
    }
}
