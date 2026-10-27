import SwiftUI

/// Name is locked inside a known room, since retyping it would quietly save the reading to a different room.
struct SaveRoomSection: View {
    @Binding var roomName: String
    let isNameLocked: Bool
    let isSaved: Bool
    let onSave: () -> Void
    @Environment(\.mothPalette) private var palette

    init(roomName: Binding<String>, isNameLocked: Bool = false, isSaved: Bool, onSave: @escaping () -> Void) {
        self._roomName = roomName
        self.isNameLocked = isNameLocked
        self.isSaved = isSaved
        self.onSave = onSave
    }

    var body: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 14) {
                MothSectionHeader("Save to a room")

                if isNameLocked {
                    HStack(spacing: 10) {
                        Image(systemName: "house")
                            .foregroundStyle(palette.accent)
                        Text(roomName)
                            .font(.moth(.subheadline, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Image(systemName: "lock")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
                } else {
                    TextField("Room name, e.g. \"Bedroom\"", text: $roomName)
                        .mothField()
                        .disabled(isSaved)
                        .submitLabel(.done)
                }

                ZStack {
                    if isSaved {
                        Label("Saved", systemImage: "checkmark.circle")
                            .font(.moth(.headline, weight: .bold))
                            .foregroundStyle(palette.success)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
                            .transition(.mothSwap)
                    } else {
                        Button {
                            onSave()
                        } label: {
                            Text("Save")
                        }
                        .buttonStyle(.mothPrimary)
                        .disabled(roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .transition(.mothSwap)
                    }
                }
                .animation(MothTheme.Motion.smooth, value: isSaved)
            }
        }
        .sensoryFeedback(.success, trigger: isSaved) { _, saved in saved }
    }
}
