import MeasurementCore
import MothCapture
import MothPersistence
import SwiftUI

/// Onboarding, then camera access, then a first calibration gate everything: an
/// uncalibrated Tier 3 reading is a much weaker product than a one-time calibration unlocks.
/// The gate never reappears, but Measure still refuses a stale calibration. A calibration
/// from an older measurement method is different: it gets a non-blocking banner, not the gate.
public struct MothRootView: View {
    private enum Tab: Hashable { case measure, rooms, buildings, settings }

    /// Exists only so stage handoffs animate as one changing value.
    private enum Stage: Hashable { case onboarding, cameraAccess, calibration, main }

    @State private var settings: UserSettings
    private let settingsStorage: UserSettingsStorage
    @State private var store: MothStore

    @State private var measurementRunner = MeasurementRunner(
        flickerAnalyzer: RealFlickerAnalyzer(),
        calibrator: RealDeviceCalibrator()
    )
    @State private var measureViewModel: MeasureViewModel?
    @State private var calibrationViewModel: CalibrationViewModel?

    @State private var selectedTab: Tab = .measure
    /// Room IDs rather than `NavigationPath`, so deleting a room can pop just its screen.
    @State private var roomsPath: [UUID] = []
    @State private var buildingsPath: [UUID] = []
    @State private var showingCalibrationSheet = false
    @State private var showingMainsChangeInvalidatedAlert = false
    @State private var showingStoreFailureAlert = false
    @State private var storeErrorMessage: String?

    /// Seeded from the system so a returning device never sees the gate again.
    @State private var hasCameraAccess = CapturePermissions.camera.isUsable

    // MARK: - Rooms/Buildings interaction state

    @State private var showingAddRoom = false
    @State private var showingAddBuilding = false
    /// Consumed in the add sheet's `onDismiss`: presenting a sheet in the same update that
    /// dismisses another is a SwiftUI race.
    @State private var roomPendingMeasurementAfterCreation: Room?
    @State private var roomBeingMeasured: Room?
    /// Consumed in the measure sheet's `onDismiss`, like `roomPendingMeasurementAfterCreation`.
    @State private var recalibrateAfterMeasureSheet = false
    @State private var roomPendingBuildingAssignment: Room?
    @State private var roomPendingRename: Room?
    @State private var buildingPendingRename: Building?
    /// Shared by both rename alerts; seeded with the current name when one opens.
    @State private var renameText = ""
    @State private var roomPendingDeletion: Room?
    @State private var buildingPendingDeletion: Building?

    @Environment(\.mothPalette) private var palette

    public init() {
        settingsStorage = UserSettingsStorage()
        let openedStore: MothStore
        if let store = try? MothStore.makeDefault() {
            openedStore = store
            _showingStoreFailureAlert = State(initialValue: false)
        } else {
            // In-memory keeps the session usable instead of crashing; the alert makes the
            // degradation visible. A second failure is a schema bug, hence the precondition.
            guard let inMemory = try? MothStore.makeInMemory() else {
                preconditionFailure("MothStore.makeInMemory() failed to build its own schema")
            }
            openedStore = inMemory
            _showingStoreFailureAlert = State(initialValue: true)
        }
        _store = State(initialValue: openedStore)

        var loadedSettings = settingsStorage.load() ?? .default
        // Builds from before settings were saved never recorded onboarding; anyone with
        // data on disk has been through it.
        if !loadedSettings.hasCompletedOnboarding,
           !openedStore.calibrations.isEmpty || !openedStore.rooms.isEmpty {
            loadedSettings.hasCompletedOnboarding = true
        }
        _settings = State(initialValue: loadedSettings)
    }

    public var body: some View {
        // Presenting modifiers must live inside `MothThemedRoot`'s content, or what they
        // present inherits the unthemed environment.
        MothThemedRoot(appearance: settings.appearance, animationsEnabled: settings.animationsEnabled) {
            ZStack {
                if !settings.hasCompletedOnboarding {
                    OnboardingView { settings.hasCompletedOnboarding = true }
                        .transition(stageTransition)
                } else if !hasCameraAccess {
                    CameraAccessGateView { hasCameraAccess = true }
                        .transition(stageTransition)
                } else if hasEverCalibratedThisDevice {
                    mainTabs
                        .transition(stageTransition)
                } else {
                    NavigationStack {
                        calibrationScreen
                            .mothCenteredTitle("Calibration")
                    }
                    .transition(stageTransition)
                }
            }
            .animation(.smooth(duration: 0.35), value: stage)
            .task {
                ensureMainsRegionDefault()
                if hasCameraAccess { ensureMeasureViewModel() }
            }
            .onChange(of: hasCameraAccess) { _, granted in
                if granted { ensureMeasureViewModel() }
            }
            .onChange(of: settings, initial: true) { _, newValue in
                settingsStorage.save(newValue)
            }
            .onChange(of: settings.mainsRegion) { _, newValue in
                invalidateCalibrationIfMainsChanged(to: newValue)
            }
            .alert("Recalibration needed", isPresented: $showingMainsChangeInvalidatedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Changing the mains frequency setting invalidated your calibration, since it was solved against the old frequency. Recalibrate to get frequency readings again.")
            }
            .alert("Couldn't open saved data", isPresented: $showingStoreFailureAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Moth couldn't open its saved rooms and measurements, so it's starting fresh for this session. Nothing you save now will be lost, but earlier data may be unavailable.")
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { storeErrorMessage != nil },
                set: { isPresented in if !isPresented { storeErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(storeErrorMessage ?? "")
            }
            .sheet(
                isPresented: $showingCalibrationSheet,
                // Covers Close and swipe-down alike: no capture keeps running unseen.
                onDismiss: { calibrationViewModel?.cancel() }
            ) {
                NavigationStack {
                    calibrationScreen
                        .mothCenteredTitle("Calibration")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingCalibrationSheet = false }
                            }
                        }
                }
            }
        }
    }

    private var stage: Stage {
        if !settings.hasCompletedOnboarding { return .onboarding }
        if !hasCameraAccess { return .cameraAccess }
        return hasEverCalibratedThisDevice ? .main : .calibration
    }

    /// Crossfade, no zoom: nothing on screen should lurch.
    private var stageTransition: AnyTransition {
        .opacity
    }

    /// Only for regions `MainsRegion.inferred` is confident about; elsewhere the user is asked.
    private func ensureMainsRegionDefault() {
        guard settings.mainsRegion == nil else { return }
        settings.mainsRegion = MainsRegion.inferred(fromRegionCode: Locale.current.region?.identifier)
    }

    /// A calibration solved for the old mains frequency would yield confident, wrong
    /// frequencies. The record is kept; only `calibrationState`'s reading of it changes.
    private func invalidateCalibrationIfMainsChanged(to newValue: MainsRegion?) {
        guard case .calibrated(let calibrated) = storedCalibrationState else { return }
        guard let newValue, calibrated.referenceFrequencyHz != newValue.referenceFlickerFrequencyHz else { return }
        showingMainsChangeInvalidatedAlert = true
    }

    private func handleStoreError(_ error: Error) {
        storeErrorMessage = (error as? LocalizedError)?.errorDescription ?? "Something went wrong saving that."
    }

    // MARK: - Calibration state

    /// Ignores the mains setting; drives the one-time first-run gate. Format-aware once the
    /// camera has reported its standard format, so a calibration from another format reads as
    /// `.outdated` before a capture, not only inside one.
    private var storedCalibrationState: CalibrationState {
        let model = DeviceIdentity.modelIdentifier
        if let format = measureViewModel?.captureFormat {
            return store.calibrationState(forDeviceModelIdentifier: model, format: format)
        }
        return store.calibrationState(forDeviceModelIdentifier: model)
    }

    /// Stays true once set, so the full-screen gate never reappears. An outdated calibration
    /// still counts: that user has calibrated before and gets a banner instead.
    private var hasEverCalibratedThisDevice: Bool {
        switch storedCalibrationState {
        case .calibrated, .outdated: return true
        default: return false
        }
    }

    /// A reading, not a stored flag, so nothing has to be written when mains changes.
    private var calibrationState: CalibrationState {
        let stored = storedCalibrationState
        guard case .calibrated(let calibration) = stored,
              let mainsRegion = settings.mainsRegion,
              calibration.referenceFrequencyHz != mainsRegion.referenceFlickerFrequencyHz
        else {
            return stored
        }
        return .uncalibrated
    }

    private var calibration: DeviceCalibration? { calibrationState.usableCalibration }

    // MARK: - Measure

    /// Keeps the hidden Measure tab from holding a second preview layer on the shared session.
    private var measureTab: some View {
        NavigationStack {
            measureContent(showsLivePreview: selectedTab == .measure)
                .mothCenteredTitle("Measure")
        }
    }

    /// Shared by the Measure tab and the "Measure This Room" sheet.
    @ViewBuilder
    private func measureContent(presetRoomName: String? = nil, showsLivePreview: Bool = true) -> some View {
        // Outdated still measures (presence only, Tier 3) under a banner; anything else
        // uncalibrated is blocked until calibrated.
        if !calibrationState.isCalibrated && !calibrationState.isOutdated {
            calibrationRequiredPrompt
        } else if let measureViewModel {
            MeasureView(
                viewModel: measureViewModel,
                presetRoomName: presetRoomName,
                showsLivePreview: showsLivePreview,
                onRecalibrate: calibrationState.isOutdated ? { beginRecalibrating() } : nil
            ) { draft, comfortRating, roomName in
                saveMeasurement(draft: draft, comfortRating: comfortRating, roomName: roomName)
            }
        } else {
            LoadingView(message: "Getting the camera ready…")
        }
    }

    /// Rooms and Settings stay reachable; only measuring is blocked.
    private var calibrationRequiredPrompt: some View {
        VStack(spacing: 16) {
            MothIconBadge(systemImage: "camera.metering.unknown", color: palette.warning, size: 72)
                .padding(.bottom, 4)
            Text("Calibration needed")
                .font(.moth(.title2, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Text("Moth needs a valid calibration on this phone before it can measure, so every reading can compare fairly against IEEE 1789. It takes about twenty seconds.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button("Calibrate now") { beginRecalibrating() }
                .buttonStyle(.mothPrimary)
                .padding(.top, 8)
        }
        .padding(MothTheme.sectionSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mothScreenBackground()
        .mothAppear()
    }

    /// From inside a room's measure sheet, waits for it to close first (see
    /// `roomPendingMeasurementAfterCreation` for why).
    private func beginRecalibrating() {
        if roomBeingMeasured != nil {
            recalibrateAfterMeasureSheet = true
            roomBeingMeasured = nil
        } else {
            showingCalibrationSheet = true
        }
    }

    private func ensureMeasureViewModel() {
        guard measureViewModel == nil else { return }
        measureViewModel = MeasureViewModel(
            runner: measurementRunner,
            calibration: { calibration }
        )
    }

    private func saveMeasurement(draft: MeasurementDraft, comfortRating: Int?, roomName: String) {
        let trimmedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // `saveMeasurement` resolves the room from `roomName`, so this ID is a throwaway.
        let measurement = draft.measurement(roomID: UUID(), comfortRating: comfortRating, mainsRegion: settings.mainsRegion)
        do {
            try store.saveMeasurement(measurement, roomName: trimmedName)
        } catch {
            handleStoreError(error)
        }
    }

    // MARK: - Rooms

    private var roomsTab: some View {
        NavigationStack(path: $roomsPath) {
            RoomsListView(
                buildingSummaries: buildingSummaries,
                onSelect: { roomsPath.append($0.room.id) },
                onAddRoom: { showingAddRoom = true },
                onAddBuilding: { showingAddBuilding = true },
                onAssignBuilding: { roomPendingBuildingAssignment = $0 },
                onRenameRoom: beginRenaming,
                onDeleteRoom: { roomPendingDeletion = $0 }
            )
            .mothCenteredTitle("Rooms")
            .navigationDestination(for: UUID.self) { roomID in
                LiveDestination { roomDetail(for: roomID) }
            }
        }
    }

    private var buildingsTab: some View {
        NavigationStack(path: $buildingsPath) {
            BuildingListView(
                buildingSummaries: buildingSummaries,
                onSelectRoom: { buildingsPath.append($0.room.id) },
                onAddBuilding: { showingAddBuilding = true },
                onAssignBuilding: { roomPendingBuildingAssignment = $0 },
                onRenameRoom: beginRenaming,
                onDeleteRoom: { roomPendingDeletion = $0 },
                onRenameBuilding: beginRenaming,
                onDeleteBuilding: { buildingPendingDeletion = $0 }
            )
            .mothCenteredTitle("Buildings")
            .navigationDestination(for: UUID.self) { roomID in
                LiveDestination { roomDetail(for: roomID) }
            }
        }
    }

    /// Always wrapped in `LiveDestination`.
    @ViewBuilder
    private func roomDetail(for roomID: UUID) -> some View {
        if let summary = roomSummaries.first(where: { $0.room.id == roomID }) {
            RoomDetailView(
                summary: summary,
                fixtureType: fixtureTypeBinding(for: roomID),
                notes: notesBinding(for: roomID),
                copingStrategies: copingStrategiesBinding(for: roomID),
                customCopingStrategies: store.customCopingStrategies,
                customCopingStrategyIDs: customCopingStrategyIDsBinding(for: roomID),
                onAddCustomCopingStrategy: { addCustomCopingStrategy(title: $0, checkedInRoomID: roomID) },
                onDeleteCustomCopingStrategy: deleteCustomCopingStrategy,
                onMeasure: { beginMeasuring(summary.room) },
                onAssignBuilding: { roomPendingBuildingAssignment = summary.room },
                onRename: { beginRenaming(summary.room) },
                onDelete: { roomPendingDeletion = summary.room }
            )
            .mothCenteredTitle(summary.room.name)
        }
    }

    /// Sheets attach to the `TabView` because one tab's sheet can't present over another tab.
    private var mainTabs: some View {
        attachRoomAlerts(to: attachRoomSheets(to:
            TabView(selection: $selectedTab) {
                measureTab
                    .tag(Tab.measure)
                    .tabItem { Label("Measure", systemImage: "scope") }

                roomsTab
                    .tag(Tab.rooms)
                    .tabItem { Label("Rooms", systemImage: "house") }

                buildingsTab
                    .tag(Tab.buildings)
                    .tabItem { Label("Buildings", systemImage: "building.2") }

                settingsTab
                    .tag(Tab.settings)
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }
        ))
    }

    private func attachRoomAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert("Rename room", isPresented: isPresent($roomPendingRename), presenting: roomPendingRename) { room in
                TextField("Room name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { renameRoom(room.id, to: renameText) }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Rename building", isPresented: isPresent($buildingPendingRename), presenting: buildingPendingRename) { building in
                TextField("Building name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { renameBuilding(building.id, to: renameText) }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(
                "Delete \(roomPendingDeletion?.name ?? "room")?",
                isPresented: isPresent($roomPendingDeletion),
                presenting: roomPendingDeletion
            ) { room in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteRoom(room.id) }
            } message: { room in
                Text(roomDeletionMessage(room))
            }
            .alert(
                "Delete \(buildingPendingDeletion?.name ?? "building")?",
                isPresented: isPresent($buildingPendingDeletion),
                presenting: buildingPendingDeletion
            ) { building in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteBuilding(building.id) }
            } message: { _ in
                Text("Its rooms and their readings are kept and move to Unassigned.")
            }
    }

    private func isPresent<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { isPresented in if !isPresented { value.wrappedValue = nil } }
        )
    }

    private func roomDeletionMessage(_ room: Room) -> String {
        let count = measurements.filter { $0.roomID == room.id }.count
        switch count {
        case 0: return "This can't be undone."
        case 1: return "Its reading will be deleted too. This can't be undone."
        default: return "Its \(count) readings will be deleted too. This can't be undone."
        }
    }

    private func attachRoomSheets<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $showingAddBuilding) {
                AddBuildingView { name in
                    createBuilding(name: name)
                }
            }
            .sheet(
                isPresented: $showingAddRoom,
                onDismiss: {
                    if let pending = roomPendingMeasurementAfterCreation {
                        roomPendingMeasurementAfterCreation = nil
                        beginMeasuring(pending)
                    }
                }
            ) {
                AddRoomView(buildings: buildings) { name, buildingID in
                    createRoom(name: name, buildingID: buildingID)
                }
            }
            .sheet(item: $roomPendingBuildingAssignment) { room in
                AssignBuildingSheet(
                    room: room,
                    buildings: buildings,
                    onAssign: { assignBuilding($0, toRoomID: room.id) },
                    onCreateAndAssign: { createBuildingAndAssign(name: $0, toRoomID: room.id) }
                )
            }
            .sheet(
                item: $roomBeingMeasured,
                onDismiss: {
                    // `measureViewModel` is shared with the Measure tab, so a stuck state must
                    // not survive the sheet closing.
                    measureViewModel?.reset()
                    if recalibrateAfterMeasureSheet {
                        recalibrateAfterMeasureSheet = false
                        showingCalibrationSheet = true
                    }
                }
            ) { room in
                NavigationStack {
                    measureContent(presetRoomName: room.name)
                        .mothCenteredTitle(room.name)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { roomBeingMeasured = nil }
                            }
                        }
                }
            }
    }

    /// Resets the shared view model first, so a stale result can't be shown or saved against
    /// the wrong room.
    private func beginMeasuring(_ room: Room) {
        measureViewModel?.reset()
        roomBeingMeasured = room
    }

    private func createRoom(name: String, buildingID: UUID?) {
        do {
            roomPendingMeasurementAfterCreation = try store.createRoom(name: name, buildingID: buildingID)
        } catch {
            handleStoreError(error)
        }
    }

    private func createBuilding(name: String) {
        do {
            try store.createBuilding(name: name)
        } catch {
            handleStoreError(error)
        }
    }

    private func assignBuilding(_ buildingID: UUID?, toRoomID roomID: UUID) {
        do {
            try store.updateRoomBuilding(roomID: roomID, buildingID: buildingID)
        } catch {
            handleStoreError(error)
        }
    }

    private func createBuildingAndAssign(name: String, toRoomID roomID: UUID) {
        do {
            let building = try store.createBuilding(name: name)
            try store.updateRoomBuilding(roomID: roomID, buildingID: building.id)
        } catch {
            handleStoreError(error)
        }
    }

    private func beginRenaming(_ room: Room) {
        renameText = room.name
        roomPendingRename = room
    }

    private func beginRenaming(_ building: Building) {
        renameText = building.name
        buildingPendingRename = building
    }

    private func renameRoom(_ roomID: UUID, to name: String) {
        do {
            try store.renameRoom(id: roomID, to: name)
        } catch {
            handleStoreError(error)
        }
    }

    private func renameBuilding(_ buildingID: UUID, to name: String) {
        do {
            try store.renameBuilding(id: buildingID, to: name)
        } catch {
            handleStoreError(error)
        }
    }

    /// Pops the room's screen in both tabs first, so neither is left showing a blank detail.
    private func deleteRoom(_ roomID: UUID) {
        roomsPath.removeAll { $0 == roomID }
        buildingsPath.removeAll { $0 == roomID }
        do {
            try store.deleteRoom(id: roomID)
        } catch {
            handleStoreError(error)
        }
    }

    private func deleteBuilding(_ buildingID: UUID) {
        do {
            try store.deleteBuilding(id: buildingID)
        } catch {
            handleStoreError(error)
        }
    }

    private var buildings: [Building] { store.buildings }
    private var rooms: [Room] { store.rooms }
    private var measurements: [RoomMeasurement] { store.measurements }

    private var roomSummaries: [RoomSummary] {
        rooms.map { room in
            RoomSummary(
                room: room,
                building: buildings.first { $0.id == room.buildingID },
                measurements: measurements.filter { $0.roomID == room.id }
            )
        }
    }

    private var buildingSummaries: [BuildingSummary] {
        let grouped = Dictionary(grouping: roomSummaries) { $0.room.buildingID }
        var summaries = grouped.map { buildingID, roomsInBuilding in
            BuildingSummary(building: buildings.first { $0.id == buildingID }, rooms: roomsInBuilding)
        }
        // Buildings with no rooms have no key in `grouped`, so add them explicitly.
        let representedBuildingIDs = Set(summaries.compactMap { $0.building?.id })
        for building in buildings where !representedBuildingIDs.contains(building.id) {
            summaries.append(BuildingSummary(building: building, rooms: []))
        }
        return summaries.sorted { lhs, rhs in
            if lhs.worstSeverity != rhs.worstSeverity { return lhs.worstSeverity > rhs.worstSeverity }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func fixtureTypeBinding(for roomID: UUID) -> Binding<FixtureType> {
        Binding(
            get: { rooms.first { $0.id == roomID }?.fixtureType ?? .unknown },
            set: { newValue in
                do {
                    try store.updateFixtureType(roomID: roomID, fixtureType: newValue)
                } catch {
                    handleStoreError(error)
                }
            }
        )
    }

    private func notesBinding(for roomID: UUID) -> Binding<String> {
        Binding(
            get: { rooms.first { $0.id == roomID }?.notes ?? "" },
            set: { newValue in
                do {
                    try store.updateNotes(roomID: roomID, notes: newValue)
                } catch {
                    handleStoreError(error)
                }
            }
        )
    }

    private func copingStrategiesBinding(for roomID: UUID) -> Binding<Set<CopingStrategy>> {
        Binding(
            get: { rooms.first { $0.id == roomID }?.copingStrategies ?? [] },
            set: { newValue in
                do {
                    try store.updateCopingStrategies(roomID: roomID, strategies: newValue)
                } catch {
                    handleStoreError(error)
                }
            }
        )
    }

    private func customCopingStrategyIDsBinding(for roomID: UUID) -> Binding<Set<UUID>> {
        Binding(
            get: { rooms.first { $0.id == roomID }?.customCopingStrategyIDs ?? [] },
            set: { newValue in
                do {
                    try store.updateCustomCopingStrategies(roomID: roomID, strategyIDs: newValue)
                } catch {
                    handleStoreError(error)
                }
            }
        )
    }

    /// Checks it off where it was typed: adding it there says it helps there.
    private func addCustomCopingStrategy(title: String, checkedInRoomID roomID: UUID) {
        do {
            let strategy = try store.addCustomCopingStrategy(title: title)
            var checked = rooms.first { $0.id == roomID }?.customCopingStrategyIDs ?? []
            checked.insert(strategy.id)
            try store.updateCustomCopingStrategies(roomID: roomID, strategyIDs: checked)
        } catch {
            handleStoreError(error)
        }
    }

    private func deleteCustomCopingStrategy(id: UUID) {
        do {
            try store.deleteCustomCopingStrategy(id: id)
        } catch {
            handleStoreError(error)
        }
    }

    // MARK: - Settings

    private var settingsTab: some View {
        NavigationStack {
            SettingsView(
                settings: $settings,
                calibrationState: calibrationState,
                onRecalibrate: { beginRecalibrating() },
                onResetCalibration: { resetCalibration() },
                onForgetEverything: { forgetEverything() }
            )
            .mothCenteredTitle("Settings")
        }
    }

    /// Rooms, buildings, and measurements are untouched.
    private func resetCalibration() {
        do {
            try store.resetCalibration(forDeviceModelIdentifier: DeviceIdentity.modelIdentifier)
        } catch {
            handleStoreError(error)
        }
    }

    /// Debug only, for demoing onboarding. Wipes the store first so no calibration remains to
    /// warn about. Camera permission can't be revoked from here.
    private func forgetEverything() {
        do {
            try store.wipeAll()
        } catch {
            handleStoreError(error)
            return
        }
        measureViewModel?.reset()
        calibrationViewModel = nil
        showingCalibrationSheet = false
        roomBeingMeasured = nil
        roomPendingBuildingAssignment = nil
        roomPendingMeasurementAfterCreation = nil
        roomPendingRename = nil
        buildingPendingRename = nil
        roomPendingDeletion = nil
        buildingPendingDeletion = nil
        roomsPath = []
        buildingsPath = []
        selectedTab = .measure
        settings = .default
        ensureMainsRegionDefault()
    }

    // MARK: - Calibration

    @ViewBuilder
    private var calibrationScreen: some View {
        if calibrationViewModel == nil {
            let vm = CalibrationViewModel(runner: measurementRunner, initialMainsRegion: settings.mainsRegion)
            LoadingView().onAppear { calibrationViewModel = vm }
        } else if let calibrationViewModel {
            CalibrationView(viewModel: calibrationViewModel, debugModeEnabled: settings.debugModeEnabled) { newCalibration in
                do {
                    try store.addCalibration(newCalibration)
                } catch {
                    handleStoreError(error)
                }
                settings.mainsRegion = MainsRegion.allCases.first {
                    $0.referenceFlickerFrequencyHz == newCalibration.referenceFrequencyHz
                }
                showingCalibrationSheet = false
                self.calibrationViewModel = nil
                Task { await measureViewModel?.refreshCaptureFormat() }
            }
        }
    }
}

/// Builds the pushed screen in its own `body` so its `MothStore` reads are observed;
/// `navigationDestination` closures aren't tracked, so pushed screens went stale.
private struct LiveDestination<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}
