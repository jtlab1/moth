import SwiftUI

public struct LoadingView: View {
    let message: String

    @Environment(\.mothPalette) private var palette

    public init(message: String = "Loading…") {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 20) {
            MothOrb(size: 130)
            Text(message)
                .font(.moth(.subheadline, weight: .medium))
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mothScreenBackground()
        .transition(.opacity)
    }
}

#Preview("Light") {
    LoadingView(message: "Getting the camera ready…")
        .environment(\.mothPalette, MothTheme.light)
}

#Preview("Dark") {
    LoadingView(message: "Getting the camera ready…")
        .environment(\.mothPalette, MothTheme.dark)
}
