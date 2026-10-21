import MeasurementCore
import SwiftUI

/// Both entry points (row swipe, detail button) open this one sheet.
struct AssignBuildingSheet: View {
    let room: Room
    let buildings: [Building]
    let onAssign: (UUID?) -> Void
    let onCreateAndAssign: (String) -> Void

    @Environment(\.mothPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var newBuildingName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MothTheme.sectionSpacing) {
                    if !buildings.isEmpty {
                        existingBuildingsCard
                    }
                    newBuildingCard
                    if room.buildingID != nil {
                        removeCard
                    }
                }
                .padding(MothTheme.sectionSpacing)
            }
            .mothScreenBackground()
            .mothCenteredTitle("Assign to Building")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var existingBuildingsCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 10) {
                MothSectionHeader("Existing buildings")
                ForEach(buildings) { building in
                    existingBuildingRow(building)
                }
            }
        }
    }

    /// One view with an explicit `.contentShape` and an overlay divider, so the whole row,
    /// `Spacer` included, is one tap target the divider can't steal.
    private func existingBuildingRow(_ building: Building) -> some View {
        Button {
            onAssign(building.id)
            dismiss()
        } label: {
            HStack {
                Text(building.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Image(systemName: building.id == room.buildingID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(building.id == room.buildingID ? palette.accent : palette.divider)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mothPressable)
        .overlay(alignment: .bottom) {
            if building.id != buildings.last?.id {
                Divider().overlay(palette.divider)
            }
        }
    }

    private var newBuildingCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 10) {
                MothSectionHeader("New building")
                TextField("Building name, e.g. \"Main Office\"", text: $newBuildingName)
                    .mothField()
                Button("Create & Assign") {
                    onCreateAndAssign(newBuildingName)
                    dismiss()
                }
                .buttonStyle(.mothPrimary)
                .disabled(newBuildingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var removeCard: some View {
        MothCard {
            Button("Remove From Building") {
                onAssign(nil)
                dismiss()
            }
            .buttonStyle(.mothDestructive)
        }
    }
}
