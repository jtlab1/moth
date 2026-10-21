import MeasurementCore
import SwiftUI

/// One screen, not a pager: it fits, there's no hidden page to wonder about, and nothing
/// slides sideways.
public struct OnboardingView: View {
    let onFinished: () -> Void

    @Environment(\.mothPalette) private var palette
    @State private var showingTerms = false

    private let steps = [
        "Calibrate once. About ten seconds.",
        "Point at a light and hold still.",
        "Save the room and see what might help."
    ]

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, MothTheme.sectionSpacing + 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MothOrb(size: 150, systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        Text("Find the lights that feel okay")
                            .font(.moth(.largeTitle, weight: .heavy))
                            .foregroundStyle(palette.primaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("Some lights flicker too fast to notice, but your eyes and brain still respond to it. Moth checks with your phone\u{2019}s camera.")
                            .font(.body)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .mothAppear(delay: 0.1)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.moth(.subheadline, weight: .heavy))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 30, height: 30)
                                    .background(palette.accentSoft, in: Circle())
                                    .accessibilityHidden(true)
                                Text(step)
                                    .font(.body)
                                    .foregroundStyle(palette.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text("Step \(index + 1): \(step)"))
                        }
                    }
                    .mothAppear(delay: 0.25)
                }
                .padding(.horizontal, MothTheme.sectionSpacing + 4)
                .padding(.vertical, 12)
            }

            VStack(spacing: 12) {
                termsNotice
                Button("Agree and get started") { onFinished() }
                    .buttonStyle(.mothPrimary)
            }
            .padding(MothTheme.sectionSpacing + 4)
        }
        .mothScreenBackground()
        .sheet(isPresented: $showingTerms) {
            NavigationStack {
                TermsView()
                    .mothCenteredTitle("Terms & Disclaimer")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingTerms = false }
                        }
                    }
            }
        }
    }

    /// Continuing is agreeing to the terms, so they sit right above the button.
    private var termsNotice: some View {
        VStack(spacing: 4) {
            Text("\(TermsView.shortNotice) By continuing, you agree to the terms.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Read the Terms & Disclaimer") { showingTerms = true }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.accent)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
    }

    /// Skip is overlaid so it never pushes the mark off-centre.
    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                // In the app target's asset catalog, so it resolves from the main bundle.
                Image(decorative: "MothMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("Moth")
                    .font(.moth(.title3, weight: .heavy))
                    .foregroundStyle(palette.primaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Button("Skip") { onFinished() }
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .frame(minWidth: 44, minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 44)
    }
}

#Preview("Dark") {
    MothThemedRoot(appearance: .dark) {
        OnboardingView(onFinished: {})
    }
}

#Preview("Light") {
    MothThemedRoot(appearance: .light) {
        OnboardingView(onFinished: {})
    }
}
