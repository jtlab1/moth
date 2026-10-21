import SwiftUI

struct AddBuildingView: View {
    let onCreate: (String) -> Void

    @Environment(\.mothPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MothTheme.sectionSpacing) {
                    MothCard {
                        VStack(alignment: .leading, spacing: 14) {
                            MothSectionHeader("Building name")
                            TextField("e.g. \"Main Office\"", text: $name)
                                .mothField()

                            Button {
                                onCreate(name)
                                dismiss()
                            } label: {
                                Label("Create Building", systemImage: "plus")
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
            .mothCenteredTitle("Add Building")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
