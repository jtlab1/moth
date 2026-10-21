import MeasurementCore
import SwiftUI

/// Numbered steps with sources folded away, so it reads as "what you can do", not citations.
struct FixesSection: View {
    let rules: [GuidanceRule]
    @Environment(\.mothPalette) private var palette
    @State private var showsSources = false

    var body: some View {
        if !rules.isEmpty {
            MothCard {
                VStack(alignment: .leading, spacing: 14) {
                    MothSectionHeader("What you can try", subtitle: "Small steps, in any order.")

                    ForEach(Array(steps.enumerated()), id: \.offset) { index, action in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.moth(.footnote, weight: .heavy))
                                .foregroundStyle(palette.accent)
                                .frame(width: 26, height: 26)
                                .background(palette.accentSoft, in: Circle())
                                .accessibilityHidden(true)
                            Text(action)
                                .font(.body)
                                .foregroundStyle(palette.primaryText.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    DisclosureGroup(isExpanded: $showsSources) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rules) { rule in
                                Text(rule.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(palette.secondaryText)
                            }
                            ForEach(sources, id: \.name) { source in
                                if let url = source.url {
                                    Link(source.name, destination: url)
                                        .font(.footnote)
                                } else {
                                    Text(source.name)
                                        .font(.footnote)
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    } label: {
                        Text(sources.count == 1 ? "1 source" : "\(sources.count) sources")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .frame(minHeight: 44)
                    }
                    .tint(palette.accent)
                }
            }
        }
    }

    private var steps: [String] { rules.flatMap(\.actions) }
    private var sources: [GuidanceSource] { rules.flatMap(\.sources) }
}
