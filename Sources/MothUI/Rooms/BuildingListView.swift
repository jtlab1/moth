import MeasurementCore
import SwiftUI

/// Same order as `RoomsListView` so the tabs never disagree, but empty buildings get a card:
/// the one place a new building is visible before it has rooms.
public struct BuildingListView: View {
    let buildingSummaries: [BuildingSummary]
    let onSelectRoom: (RoomSummary) -> Void
    let onAddBuilding: () -> Void
    let onAssignBuilding: (Room) -> Void
    let onRenameRoom: (Room) -> Void
    let onDeleteRoom: (Room) -> Void
    let onRenameBuilding: (Building) -> Void
    let onDeleteBuilding: (Building) -> Void

    @Environment(\.mothPalette) private var palette

    public init(
        buildingSummaries: [BuildingSummary],
        onSelectRoom: @escaping (RoomSummary) -> Void,
        onAddBuilding: @escaping () -> Void,
        onAssignBuilding: @escaping (Room) -> Void,
        onRenameRoom: @escaping (Room) -> Void,
        onDeleteRoom: @escaping (Room) -> Void,
        onRenameBuilding: @escaping (Building) -> Void,
        onDeleteBuilding: @escaping (Building) -> Void
    ) {
        self.buildingSummaries = buildingSummaries
        self.onSelectRoom = onSelectRoom
        self.onAddBuilding = onAddBuilding
        self.onAssignBuilding = onAssignBuilding
        self.onRenameRoom = onRenameRoom
        self.onDeleteRoom = onDeleteRoom
        self.onRenameBuilding = onRenameBuilding
        self.onDeleteBuilding = onDeleteBuilding
    }

    /// Unassigned goes last: it isn't a place anyone can visit.
    private var groups: [BuildingSummary] {
        let named = buildingSummaries.filter { $0.building != nil }
        let unassigned = buildingSummaries.filter { $0.building == nil && !$0.rooms.isEmpty }
        return named + unassigned
    }

    private var hasBuildings: Bool {
        groups.contains { $0.building != nil }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MothTheme.sectionSpacing) {
                if !hasBuildings {
                    emptyState
                        .transition(.mothSwap)
                } else {
                    Text("Buildings that need a visit come first.")
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                    ForEach(groups) { group in
                        card(group)
                    }
                }
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: groups.map(\.id))
        }
        .mothScreenBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onAddBuilding()
                } label: {
                    Label("Add building", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private func card(_ group: BuildingSummary) -> some View {
        VStack(spacing: 0) {
            header(group)

            Divider().overlay(palette.divider)

            if group.rooms.isEmpty {
                Text("No rooms yet. Add a room and pick this building, or change a room's building from its screen.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(Array(group.rooms.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 {
                        Divider()
                            .overlay(palette.divider)
                            .padding(.leading, 52)
                    }
                    Button { onSelectRoom(summary) } label: {
                        RoomRow(summary: summary)
                    }
                    .buttonStyle(.mothPressable)
                    .contextMenu {
                        RoomRowMenu(
                            room: summary.room,
                            onAssignBuilding: onAssignBuilding,
                            onRename: onRenameRoom,
                            onDelete: onDeleteRoom
                        )
                    }
                }
            }
        }
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The menu sits outside the combined accessibility element so VoiceOver can reach it.
    private func header(_ group: BuildingSummary) -> some View {
        HStack(spacing: 8) {
            headerLabel(group)
            if let building = group.building {
                buildingMenu(building)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, group.building == nil ? 16 : 4)
        .padding(.vertical, 16)
    }

    private func buildingMenu(_ building: Building) -> some View {
        Menu {
            Button {
                onRenameBuilding(building)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDeleteBuilding(building)
            } label: {
                Label("Delete building", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(palette.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(building.name) options"))
    }

    private func headerLabel(_ group: BuildingSummary) -> some View {
        HStack(spacing: 14) {
            MothIconBadge(
                systemImage: group.building == nil ? "tray" : "building.2",
                color: group.rooms.isEmpty ? nil : palette.color(for: group.worstSeverity),
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.moth(.title3, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                Text(subtitle(group))
                    .font(.subheadline)
                    .foregroundStyle(group.roomsExceedingLowRisk > 0 ? palette.color(for: .exceedsLowRisk) : palette.secondaryText)
            }
            Spacer(minLength: 8)
            if !group.rooms.isEmpty {
                MothStatusSymbol(severity: group.worstSeverity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(_ group: BuildingSummary) -> String {
        let count = group.rooms.count
        let rooms = count == 1 ? "1 room" : "\(count) rooms"
        guard group.roomsExceedingLowRisk > 0 else { return rooms }
        return "\(rooms) · \(group.roomsExceedingLowRisk) over the limit"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            MothIconBadge(systemImage: "building.2", size: 72)
            Text("No buildings yet")
                .font(.moth(.title3, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Text("Add a building to group its rooms together and see which one needs a visit first.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button("Add building") { onAddBuilding() }
                .buttonStyle(.mothPrimary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
        .mothAppear()
    }
}
