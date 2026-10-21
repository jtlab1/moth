import MeasurementCore
import SwiftUI

/// Creating and measuring a room are separate, deliberate steps.
struct AddRoomView: View {
    let buildings: [Building]
    let onCreate: (String, UUID?) -> Void

    @Environment(\.mothPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedBuildingID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MothTheme.sectionSpacing) {
                    MothCard {
                        VStack(alignment: .leading, spacing: 14) {
                            MothSectionHeader("Room name")
                            TextField("e.g. \"Bedroom\"", text: $name)
                                .mothField()

                            if !buildings.isEmpty {
                                HStack {
                                    Label("Building", systemImage: "building.2")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(palette.primaryText)
                                    Spacer()
                                    Picker("Building", selection: $selectedBuildingID) {
                                        Text("None").tag(UUID?.none)
                                        ForEach(buildings) { building in
                                            Text(building.name).tag(UUID?.some(building.id))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .tint(palette.accent)
                                }
                                .padding(.leading, 14)
                                .padding(.vertical, 4)
                                .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
                            }

                            Button {
                                onCreate(name, selectedBuildingID)
                                dismiss()
                            } label: {
                                Label("Create Room", systemImage: "plus")
                            }
                            .buttonStyle(.mothPrimary)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .mothAppear()
                }
                .padding(MothTheme.sectionSpacing)
            }
            .mothScreenBackground()
            .mothCenteredTitle("Add Room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
