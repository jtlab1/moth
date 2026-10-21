import Foundation
import Testing
import MeasurementCore
import SwiftData
@testable import MothPersistence

/// The mandatory calibration gate reads this path directly, so it must be right.
@Suite("MothStore")
@MainActor
struct MothStoreTests {

    private func makeStore() throws -> MothStore {
        try MothStore.makeInMemory()
    }

    private func calibration(model: String = "iPhone17,1", capturedAt: Date = SampleData.now) -> DeviceCalibration {
        DeviceCalibration(
            deviceModelIdentifier: model,
            lineReadoutTime: 18.5e-6,
            referenceFrequencyHz: 100,
            calibratedLineCount: 1080,
            capturedAt: capturedAt
        )
    }

    @Test("An empty store reads as uncalibrated for any device")
    func emptyStoreIsUncalibrated() throws {
        let store = try makeStore()
        #expect(store.calibrationState(forDeviceModelIdentifier: "iPhone17,1") == .uncalibrated)
    }

    @Test("A saved calibration is read back as calibrated for its own device")
    func savedCalibrationRoundTrips() throws {
        let store = try makeStore()
        let saved = calibration(model: "iPhone17,1")
        try store.addCalibration(saved)

        let state = store.calibrationState(forDeviceModelIdentifier: "iPhone17,1")
        #expect(state.usableCalibration?.id == saved.id)
        #expect(state.isCalibrated)
    }

    @Test("A calibration for a different device reads as foreignDevice, not calibrated")
    func foreignDeviceCalibrationDoesNotApply() throws {
        let store = try makeStore()
        try store.addCalibration(calibration(model: "iPhone15,2"))

        let state = store.calibrationState(forDeviceModelIdentifier: "iPhone17,1")
        #expect(!state.isCalibrated)
        if case .foreignDevice = state {} else { Issue.record("expected .foreignDevice, got \(state)") }
    }

    @Test("The most recent calibration for a device wins when several exist")
    func mostRecentCalibrationWins() throws {
        let store = try makeStore()
        let older = calibration(capturedAt: SampleData.now.addingTimeInterval(-86_400))
        let newer = calibration(capturedAt: SampleData.now)
        try store.addCalibration(older)
        try store.addCalibration(newer)

        let state = store.calibrationState(forDeviceModelIdentifier: "iPhone17,1")
        #expect(state.usableCalibration?.id == newer.id)
    }

    @Test("Older calibrations for the same device are kept, not overwritten")
    func historyIsPreserved() throws {
        let store = try makeStore()
        try store.addCalibration(calibration(capturedAt: SampleData.now.addingTimeInterval(-86_400)))
        try store.addCalibration(calibration(capturedAt: SampleData.now))
        #expect(store.calibrations.count == 2)
    }

    @Test("Resetting calibration clears this device's records and nothing else")
    func resetCalibrationClearsOnlyThisDevice() throws {
        let store = try makeStore()
        try store.addCalibration(calibration(model: "iPhone17,1", capturedAt: SampleData.now.addingTimeInterval(-86_400)))
        try store.addCalibration(calibration(model: "iPhone17,1", capturedAt: SampleData.now))
        try store.addCalibration(calibration(model: "iPhone15,2"))

        try store.resetCalibration(forDeviceModelIdentifier: "iPhone17,1")

        // Another device's record makes this `.foreignDevice`; either way `.calibrated` no
        // longer matches, which is what re-triggers the gate.
        let state = store.calibrationState(forDeviceModelIdentifier: "iPhone17,1")
        #expect(!state.isCalibrated)
        #expect(state.usableCalibration == nil)
        #expect(store.calibrations.count == 1)
        #expect(store.calibrations.first?.deviceModelIdentifier == "iPhone15,2")
    }

    @Test("Resetting an already-uncalibrated device is a harmless no-op")
    func resetCalibrationOnEmptyStoreDoesNothing() throws {
        let store = try makeStore()
        try store.resetCalibration(forDeviceModelIdentifier: "iPhone17,1")
        #expect(store.calibrationState(forDeviceModelIdentifier: "iPhone17,1") == .uncalibrated)
    }

    @Test("Saving a measurement creates its room by name, reusing an existing one case-insensitively")
    func saveMeasurementFindsOrCreatesRoom() throws {
        let store = try makeStore()
        let flicker = FlickerResult(presence: .absent, confidence: .high, tier: .tier1)
        // Distinct ids: inserting one value twice would just upsert via the unique `id`.
        let measurementA = RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0")
        let measurementB = RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0")

        let firstRoom = try store.saveMeasurement(measurementA, roomName: "Library Quiet Room")
        let secondRoom = try store.saveMeasurement(measurementB, roomName: "library quiet room")

        #expect(firstRoom.id == secondRoom.id)
        #expect(store.rooms.count == 1)
        #expect(store.measurements.count == 2)
        #expect(store.measurements.allSatisfy { $0.roomID == firstRoom.id })
    }

    @Test("wipeAll clears rooms, measurements, and calibrations")
    func wipeAllClearsEverything() throws {
        let store = try makeStore()
        try store.addCalibration(calibration())
        let flicker = FlickerResult(presence: .absent, confidence: .high, tier: .tier1)
        _ = try store.saveMeasurement(
            RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0"),
            roomName: "Lab 3"
        )
        try store.addCustomCopingStrategy(title: "Bring a cap")

        try store.wipeAll()

        #expect(store.rooms.isEmpty)
        #expect(store.measurements.isEmpty)
        #expect(store.calibrations.isEmpty)
        #expect(store.customCopingStrategies.isEmpty)
        #expect(store.calibrationState(forDeviceModelIdentifier: "iPhone17,1") == .uncalibrated)
    }

    // MARK: - Custom coping strategies

    @Test("A custom strategy is shared across rooms and checked off per room")
    func customStrategyIsSharedButCheckedPerRoom() throws {
        let store = try makeStore()
        let bedroom = try store.createRoom(name: "Bedroom")
        let office = try store.createRoom(name: "Office")

        let strategy = try store.addCustomCopingStrategy(title: "  Sit facing the window  ")
        try store.updateCustomCopingStrategies(roomID: bedroom.id, strategyIDs: [strategy.id])

        #expect(strategy.title == "Sit facing the window")
        #expect(store.customCopingStrategies.map(\.id) == [strategy.id])
        #expect(store.rooms.first { $0.id == bedroom.id }?.customCopingStrategyIDs == [strategy.id])
        #expect(store.rooms.first { $0.id == office.id }?.customCopingStrategyIDs == [])
    }

    @Test("Adding a custom strategy reuses an existing one case-insensitively and rejects blanks")
    func addCustomStrategyFindsOrCreates() throws {
        let store = try makeStore()
        let first = try store.addCustomCopingStrategy(title: "Bring a cap")
        let second = try store.addCustomCopingStrategy(title: "bring a CAP")

        #expect(first.id == second.id)
        #expect(store.customCopingStrategies.count == 1)
        #expect(throws: MothStoreError.self) { try store.addCustomCopingStrategy(title: "   ") }
    }

    @Test("Custom strategies leave the built-in checklist untouched")
    func customStrategiesDoNotTouchBuiltIns() throws {
        let store = try makeStore()
        let room = try store.createRoom(name: "Lab")
        try store.updateCopingStrategies(roomID: room.id, strategies: [.headphones])
        let strategy = try store.addCustomCopingStrategy(title: "Bring a cap")
        try store.updateCustomCopingStrategies(roomID: room.id, strategyIDs: [strategy.id])

        let stored = try #require(store.rooms.first)
        #expect(stored.copingStrategies == [.headphones])
        #expect(stored.customCopingStrategyIDs == [strategy.id])
    }

    @Test("Deleting a custom strategy removes it from the list and unchecks it in every room")
    func deleteCustomStrategyUnchecksEverywhere() throws {
        let store = try makeStore()
        let roomA = try store.createRoom(name: "A")
        let roomB = try store.createRoom(name: "B")
        let kept = try store.addCustomCopingStrategy(title: "Keep me")
        let doomed = try store.addCustomCopingStrategy(title: "Delete me")
        try store.updateCustomCopingStrategies(roomID: roomA.id, strategyIDs: [kept.id, doomed.id])
        try store.updateCustomCopingStrategies(roomID: roomB.id, strategyIDs: [doomed.id])

        try store.deleteCustomCopingStrategy(id: doomed.id)

        #expect(store.customCopingStrategies.map(\.id) == [kept.id])
        #expect(store.rooms.first { $0.id == roomA.id }?.customCopingStrategyIDs == [kept.id])
        #expect(store.rooms.first { $0.id == roomB.id }?.customCopingStrategyIDs == [])
    }

    // MARK: - Renaming and deleting rooms and buildings

    @Test("Renaming a room trims the name and rejects blanks and another room's name")
    func renameRoomValidatesName() throws {
        let store = try makeStore()
        let bedroom = try store.createRoom(name: "Bedroom")
        _ = try store.createRoom(name: "Office")

        try store.renameRoom(id: bedroom.id, to: "  Guest Room  ")
        #expect(store.rooms.first { $0.id == bedroom.id }?.name == "Guest Room")

        // Changing only the case of its own name is allowed.
        try store.renameRoom(id: bedroom.id, to: "guest room")
        #expect(store.rooms.first { $0.id == bedroom.id }?.name == "guest room")

        #expect(throws: MothStoreError.nameEmpty) { try store.renameRoom(id: bedroom.id, to: "   ") }
        #expect(throws: MothStoreError.roomNameTaken) { try store.renameRoom(id: bedroom.id, to: "OFFICE") }
        #expect(throws: MothStoreError.roomNotFound) { try store.renameRoom(id: UUID(), to: "Den") }
    }

    @Test("Renaming a building rejects another building's name")
    func renameBuildingValidatesName() throws {
        let store = try makeStore()
        let home = try store.createBuilding(name: "Home")
        _ = try store.createBuilding(name: "Work")

        try store.renameBuilding(id: home.id, to: "Apartment")
        #expect(store.buildings.first { $0.id == home.id }?.name == "Apartment")
        #expect(throws: MothStoreError.buildingNameTaken) { try store.renameBuilding(id: home.id, to: "work") }
        #expect(throws: MothStoreError.buildingNotFound) { try store.renameBuilding(id: UUID(), to: "Lab") }
    }

    @Test("Deleting a room deletes its measurements and leaves other rooms alone")
    func deleteRoomRemovesItsMeasurements() throws {
        let store = try makeStore()
        let flicker = FlickerResult(presence: .absent, confidence: .high, tier: .tier1)
        let doomed = try store.saveMeasurement(
            RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0"),
            roomName: "Lab 3"
        )
        let kept = try store.saveMeasurement(
            RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0"),
            roomName: "Lab 4"
        )

        try store.deleteRoom(id: doomed.id)

        #expect(store.rooms.map(\.id) == [kept.id])
        #expect(store.measurements.map(\.roomID) == [kept.id])
    }

    @Test("Deleting a building keeps its rooms and their measurements, now unassigned")
    func deleteBuildingUnassignsRooms() throws {
        let store = try makeStore()
        let building = try store.createBuilding(name: "Office")
        let flicker = FlickerResult(presence: .absent, confidence: .high, tier: .tier1)
        let room = try store.saveMeasurement(
            RoomMeasurement(roomID: UUID(), flicker: flicker, deviceModelIdentifier: "iPhone17,1", appVersion: "1.0"),
            roomName: "Desk",
            buildingID: building.id
        )

        try store.deleteBuilding(id: building.id)

        #expect(store.buildings.isEmpty)
        #expect(store.rooms.map(\.id) == [room.id])
        #expect(store.rooms.first?.buildingID == nil)
        #expect(store.measurements.count == 1)
    }

    // MARK: - makeDefault (real on-disk storage)

    /// Never the real Application Support directory a developer's build also uses.
    private func makeIsolatedStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Moth.store")
    }

    @Test("makeDefault persists across separate store instances pointed at the same file")
    func makeDefaultPersistsToDisk() throws {
        let storeURL = try makeIsolatedStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let first = try MothStore.makeDefault(storeURL: storeURL)
        try first.addCalibration(calibration(model: "iPhone17,1"))

        // A fresh instance on the same file stands in for the next launch.
        let second = try MothStore.makeDefault(storeURL: storeURL)
        #expect(second.calibrationState(forDeviceModelIdentifier: "iPhone17,1").isCalibrated)
    }

    @Test("makeDefault recovers by starting fresh when the file at storeURL isn't a valid store")
    func makeDefaultRecoversFromIncompatibleStore() throws {
        let storeURL = try makeIsolatedStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // Stands in for a store left by an incompatible older schema.
        try Data("not a real store".utf8).write(to: storeURL)

        let store = try MothStore.makeDefault(storeURL: storeURL)
        #expect(store.calibrationState(forDeviceModelIdentifier: "iPhone17,1") == .uncalibrated)

        try store.addCalibration(calibration(model: "iPhone17,1"))
        let reopened = try MothStore.makeDefault(storeURL: storeURL)
        #expect(reopened.calibrationState(forDeviceModelIdentifier: "iPhone17,1").isCalibrated)
    }

    @Test("A V2 store on disk migrates to V3 with its rooms and checklists intact")
    func migratesV2StoreToV3() throws {
        let storeURL = try makeIsolatedStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        // A broken migration shows up here as missing rooms, since `makeDefault` deletes
        // a store it can't open.
        let roomID = UUID()
        do {
            let v2 = try ModelContainer(
                for: Schema(versionedSchema: MothSchemaV2.self),
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(v2)
            let building = MothSchemaV2.BuildingRecord(id: UUID(), name: "Main Office", notes: "", createdAt: SampleData.now)
            context.insert(building)
            context.insert(
                MothSchemaV2.RoomRecord(
                    id: roomID,
                    name: "Bedroom",
                    building: building,
                    fixtureTypeRaw: FixtureType.unknown.rawValue,
                    notes: "Worst by the window",
                    copingStrategyRawValues: [CopingStrategy.headphones.rawValue],
                    createdAt: SampleData.now
                )
            )
            try context.save()
        }

        let store = try MothStore.makeDefault(storeURL: storeURL)
        let room = try #require(store.rooms.first { $0.id == roomID })
        #expect(room.name == "Bedroom")
        #expect(room.notes == "Worst by the window")
        #expect(room.copingStrategies == [.headphones])
        #expect(room.customCopingStrategyIDs.isEmpty)
        #expect(store.buildings.map(\.name) == ["Main Office"])

        let strategy = try store.addCustomCopingStrategy(title: "Bring a cap")
        try store.updateCustomCopingStrategies(roomID: roomID, strategyIDs: [strategy.id])
        let reopened = try MothStore.makeDefault(storeURL: storeURL)
        #expect(reopened.rooms.first { $0.id == roomID }?.customCopingStrategyIDs == [strategy.id])
    }
}
