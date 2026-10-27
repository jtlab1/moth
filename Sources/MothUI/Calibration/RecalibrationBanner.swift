import SwiftUI

/// Non-blocking banner for calibrations from an older method. Measuring still works (presence only) until recalibrated.
struct RecalibrationBanner: View {
    let onRecalibrate: () -> Void

    @Environment(\.mothPalette) private var palette

    static let message = "Moth’s measurement method changed. Recalibrate once to restore frequency and depth measurement."

    var body: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(Self.message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(palette.warning)
                }
                Text("Until then, Moth can still tell you whether a light is flickering.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onRecalibrate()
                } label: {
                    Label("Recalibrate", systemImage: "scope")
                }
                .buttonStyle(.mothSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
