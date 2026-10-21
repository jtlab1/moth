import MeasurementCore
import SwiftUI

/// One list, worst first, rather than two groupings behind a toggle.
public struct RoomsListView: View {
    let buildingSummaries: [BuildingSummary]
    let onSelect: (RoomSummary) -> Void
    let onAddRoom: () -> Void
    let onAddBuilding: () -> Void
    let onAssignBuilding: (Room) -> Void
    let onRenameRoom: (Room) -> Void
    let onDeleteRoom: (Room) -> Void

    @Environment(\.mothPalette) private var palette

    public init(
        buildingSummaries: [BuildingSummary],
        onSelect: @escaping (RoomSummary) -> Void,
        onAddRoom: @escaping () -> Void,
        onAddBuilding: @escaping () -> Void,
        onAssignBuilding: @escaping (Room) -> Void,
        onRenameRoom: @escaping (Room) -> Void,
        onDeleteRoom: @escaping (Room) -> Void
    ) {
        self.buildingSummaries = buildingSummaries
        self.onSelect = onSelect
        self.onAddRoom = onAddRoom
        self.onAddBuilding = onAddBuilding
        self.onAssignBuilding = onAssignBuilding
        self.onRenameRoom = onRenameRoom
        self.onDeleteRoom = onDeleteRoom
    }

    /// Empty buildings appear once a room is assigned; `BuildingListView` shows them earlier.
    private var groups: [BuildingSummary] {
        buildingSummaries.filter { !$0.rooms.isEmpty }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MothTheme.sectionSpacing) {
                if groups.isEmpty {
                    emptyState
                        .transition(.mothSwap)
                } else {
                    Text("Rooms that need care come first.")
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                    ForEach(groups) { group in
                        section(group)
                    }
                }
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: groups.flatMap { $0.rooms.map(\.id) })
        }
        .mothScreenBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    onAddBuilding()
                } label: {
                    Label("Add building", systemImage: "building.2")
                        .labelStyle(.titleAndIcon)
                }
                Button {
                    onAddRoom()
                } label: {
                    Label("Add room", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private func section(_ group: BuildingSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(Text(group.name))

            VStack(spacing: 0) {
                ForEach(Array(group.rooms.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 {
                        Divider()
                            .overlay(palette.divider)
                            .padding(.leading, 52)
                    }
                    Button { onSelect(summary) } label: {
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
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            MothIconBadge(systemImage: "house", size: 72)
            Text("No rooms yet")
                .font(.moth(.title3, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Text("Add a room, then measure it. Every reading you save lands here, with the rooms that need care first.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            Button("Add room") { onAddRoom() }
                .buttonStyle(.mothPrimary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
        .mothAppear()
    }
}

/// Shared by both lists' row context menus so they never offer different actions.
struct RoomRowMenu: View {
    let room: Room
    let onAssignBuilding: (Room) -> Void
    let onRename: (Room) -> Void
    let onDelete: (Room) -> Void

    var body: some View {
        Button {
            onRename(room)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            onAssignBuilding(room)
        } label: {
            Label("Change building", systemImage: "building.2")
        }
        Button(role: .destructive) {
            onDelete(room)
        } label: {
            Label("Delete room", systemImage: "trash")
        }
    }
}

struct RoomRow: View {
    let summary: RoomSummary
    @Environment(\.mothPalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            MothStatusSymbol(severity: summary.severity)
                .frame(width: 24)
            Text(summary.room.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(summary.latest == nil ? "Not measured" : summary.severity.title)
                .font(.subheadline)
                .foregroundStyle(summary.latest == nil ? palette.secondaryText : palette.color(for: summary.severity))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.secondaryText.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
