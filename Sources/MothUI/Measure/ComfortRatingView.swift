import MeasurementCore
import SwiftUI

/// Buttons, not a slider: every choice visible, one tap, nothing moving under the finger.
/// Tapping the selection again clears it.
struct ComfortRatingView: View {
    @Binding var rating: Int?
    @Environment(\.mothPalette) private var palette

    private let range = RoomMeasurement.comfortRatingRange
    private let labels: [Int: String] = [
        1: "Very uncomfortable",
        2: "Uncomfortable",
        3: "Neutral",
        4: "Comfortable",
        5: "Very comfortable"
    ]

    var body: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 14) {
                MothSectionHeader("How does it feel here?", trailing: "Optional")

                HStack(spacing: 8) {
                    ForEach(Array(range), id: \.self) { value in
                        choice(value)
                    }
                }

                HStack {
                    Text("Very uncomfortable")
                    Spacer()
                    Text("Very comfortable")
                }
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.selection, trigger: rating)
    }

    private func choice(_ value: Int) -> some View {
        let isSelected = rating == value
        let shape = RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous)
        return Button {
            rating = isSelected ? nil : value
        } label: {
            Text("\(value)")
                .font(.moth(.title3, weight: .heavy))
                .foregroundStyle(isSelected ? palette.onAccent : palette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(isSelected ? palette.accent : palette.accentSoft, in: shape)
                .overlay(shape.strokeBorder(isSelected ? palette.accent : palette.cardBorder, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.mothPressable)
        .accessibilityLabel(Text("\(value), \(labels[value] ?? "")"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
