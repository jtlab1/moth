import MeasurementCore
import SwiftUI

/// How a reading was captured, tucked away since it's only useful when readings disagree.
/// Shows nothing for old readings without conditions or notes.
struct CaptureDetailsDisclosure: View {
    let flicker: FlickerResult

    /// The result card shows notes on its own; room history has nowhere else to put them.
    var includesNotes = false

    @Environment(\.mothPalette) private var palette
    @State private var isExpanded = false

    var body: some View {
        if hasContent {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let conditions = flicker.conditions {
                        ForEach(Self.rows(for: conditions, responseCurveApplied: flicker.responseCurveApplied), id: \.label) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label)
                                    .foregroundStyle(palette.secondaryText)
                                Spacer(minLength: 12)
                                Text(row.value)
                                    .foregroundStyle(palette.primaryText)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(row.label))
                            .accessibilityValue(Text(row.spokenValue ?? row.value))
                        }
                    }
                    if includesNotes {
                        ForEach(Array(flicker.diagnosticNotes.enumerated()), id: \.offset) { _, note in
                            Label(note, systemImage: "info.circle")
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.footnote)
                .padding(.top, 6)
            } label: {
                Text("Capture details")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: 44)
            }
            .tint(palette.accent)
        }
    }

    private var hasContent: Bool {
        flicker.conditions != nil || (includesNotes && !flicker.diagnosticNotes.isEmpty)
    }

    struct Row: Hashable {
        let label: String
        let value: String
        /// When the shown value reads badly aloud ("1/4000 s").
        var spokenValue: String?
    }

    static func rows(for conditions: CaptureConditions, responseCurveApplied: Bool?) -> [Row] {
        var rows: [Row] = []
        if conditions.exposureDuration > 0 {
            let denominator = Int((1 / conditions.exposureDuration).rounded())
            rows.append(Row(
                label: "Exposure",
                value: "1/\(denominator) s",
                spokenValue: "1 over \(denominator) of a second"
            ))
        }
        rows.append(Row(label: "ISO", value: String(Int(conditions.iso.rounded()))))
        rows.append(Row(
            label: "Frame rate",
            value: String(format: "%.1f fps", conditions.frameRate),
            spokenValue: String(format: "%.1f frames per second", conditions.frameRate)
        ))
        rows.append(Row(
            label: "Picture size",
            value: conditions.formatSignature.formattedDimensions,
            spokenValue: "\(conditions.formatSignature.width) by \(conditions.formatSignature.height)"
        ))
        rows.append(Row(
            label: "Dropped frames",
            value: conditions.droppedFrameCount == 0
                ? "None"
                : "\(conditions.droppedFrameCount) of \(conditions.capturedFrameCount + conditions.droppedFrameCount)"
        ))
        if let responseCurveApplied {
            rows.append(Row(label: "Light-response curve", value: responseCurveApplied ? "Applied" : "Not applied"))
        }
        return rows
    }
}
