import SwiftUI

/// Bump `lastUpdated` for any change that matters to the user.
public struct TermsView: View {
    @Environment(\.mothPalette) private var palette

    public init() {}

    public static let shortNotice = "Moth is a benchmarking tool, not a certified or professional flicker meter. Results are estimates for reference only."

    static let lastUpdated = "October 7, 2026"

    private struct Section: Identifiable {
        let title: String
        let body: String
        var id: String { title }
    }

    private let sections: [Section] = [
        Section(
            title: "What Moth is",
            body: "Moth is a benchmarking tool meant to make light flicker measurement easier to get to. It uses your phone\u{2019}s camera to estimate how much a light flickers, so you can compare rooms and fixtures and decide whether something is worth a closer look."
        ),
        Section(
            title: "What Moth is not",
            body: "Moth is not an official, certified, calibrated, or professional light flicker measurement system, and it is not a substitute for one. Phone cameras were not designed for this, and results depend on the device, its calibration, the lighting, and how the phone is held. Two phones, or two readings on the same phone, can disagree. If you need a reliable measurement, use a dedicated instrument operated by a qualified professional."
        ),
        Section(
            title: "Not medical, safety, or compliance advice",
            body: "Nothing in Moth is medical advice, a diagnosis, or a treatment recommendation, and nothing in it tells you whether a space is safe. Talk to a qualified healthcare provider about symptoms you experience. Do not rely on Moth for workplace, building, legal, regulatory, or standards-compliance decisions, or as evidence in any dispute."
        ),
        Section(
            title: "Standards references",
            body: "Moth compares its estimates against risk levels described in IEEE 1789 to give them context. Moth is not affiliated with, endorsed by, or certified by IEEE or any other standards body, and a Moth reading is not a determination of compliance with any standard."
        ),
        Section(
            title: "Your own checklists",
            body: "The coping strategies you check off for a room, including any you add yourself, are your own notes. Moth does not claim that any of them work."
        ),
        Section(
            title: "No warranty",
            body: "Moth is provided \u{201C}as is\u{201D} and \u{201C}as available,\u{201D} without warranties of any kind, express or implied, including accuracy, reliability, fitness for a particular purpose, and non-infringement. You use Moth and its results at your own risk."
        ),
        Section(
            title: "Limitation of liability",
            body: "To the fullest extent permitted by law, the developers of Moth are not liable for any direct, indirect, incidental, consequential, or other damages arising from your use of, or reliance on, Moth or its results."
        ),
        Section(
            title: "Your data",
            body: "Measurements, rooms, and settings are stored only on this device. Moth has no accounts, no backend, and no networking."
        ),
        Section(
            title: "Agreement",
            body: "By using Moth you agree to these terms. If you do not agree, please do not use the app."
        )
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MothTheme.sectionSpacing) {
                MothCard {
                    VStack(alignment: .leading, spacing: 10) {
                        MothSectionHeader("In short")
                        Text(Self.shortNotice)
                            .font(.body)
                            .foregroundStyle(palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MothCard {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.moth(.headline))
                                    .foregroundStyle(palette.primaryText)
                                    .accessibilityAddTraits(.isHeader)
                                Text(section.body)
                                    .font(.subheadline)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Text("Last updated \(Self.lastUpdated)")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            .padding(MothTheme.sectionSpacing)
        }
        .mothScreenBackground()
    }
}

#Preview {
    MothThemedRoot(appearance: .dark) {
        NavigationStack {
            TermsView()
                .mothCenteredTitle("Terms & Disclaimer")
        }
    }
}
