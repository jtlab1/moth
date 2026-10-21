import SwiftUI

struct CaptureQualityWarning: View {
    let message: String

    @Environment(\.mothPalette) private var palette

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.warning)
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            // No pulsing symbol: a blinking icon is exactly the flicker this app points out.
            .transition(.opacity)
    }
}
