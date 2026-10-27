import Charts
import MeasurementCore
import MothCapture
import SwiftUI

/// Words, then numbers, then confidence. The technical stuff folds behind "Details" to keep the first read short.
struct MeasurementResultCard: View {
    let draft: MeasurementDraft
    @Environment(\.mothPalette) private var palette
    @Environment(\.mothMotionEnabled) private var motionEnabled
    @State private var showsDetails = false
    @State private var waveformRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            verdictHeader
                .mothAppear()

            if let explanation = draft.flicker.verdict?.explanation {
                Text(explanation)
                    .font(.body)
                    .foregroundStyle(palette.primaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .mothAppear(delay: 0.06)
            }

            // Every note: each names a different condition that cost confidence or a quantity.
            ForEach(Array(draft.flicker.diagnosticNotes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statPair
                .mothAppear(delay: 0.12)

            detailsDisclosure
                .mothAppear(delay: 0.18)

            // The caveat travels with every number; see `TermsView`.
            Text(TermsView.shortNotice)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .mothAppear(delay: 0.24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdictHeader: some View {
        HStack(spacing: 12) {
            MothStatusSymbol(severity: draft.flicker.severity, size: .title)
            Text(draft.flicker.verdict?.title ?? draft.flicker.presence.title)
                .font(.moth(.title2, weight: .heavy))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var statPair: some View {
        let frequency = draft.flicker.formattedFrequency
        let depth = draft.flicker.formattedModulationDepth
        if frequency != nil || depth != nil {
            VStack(alignment: .leading, spacing: 14) {
                Divider().overlay(palette.divider)
                HStack(alignment: .top, spacing: 12) {
                    if let frequency {
                        stat(value: frequency, label: "How fast it flickers")
                    }
                    if let depth {
                        stat(value: depth, label: "How deep it dips")
                    }
                }
            }
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.moth(.title2, weight: .heavy).monospacedDigit())
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 12) {
                if let sentence = draft.flicker.limitComparisonSentence {
                    Text(sentence)
                }
                Text(draft.flicker.tier.explanation)
                Text(draft.flicker.confidence.explanation)
                waveformSection
                CaptureDetailsDisclosure(flicker: draft.flicker)
            }
            .font(.subheadline)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            HStack {
                Text(draft.flicker.formattedConfidenceLevel)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("Details")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(minHeight: 44)
        }
        .tint(palette.accent)
    }

    /// The actual folded signal the numbers were read from, not an illustration.
    @ViewBuilder
    private var waveformSection: some View {
        if let waveform = draft.waveform, waveform.points.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Measured light signal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Text("Three cycles of the flicker Moth measured, reconstructed from the camera\u{2019}s rolling shutter.")
                    .font(.footnote)
                Chart(waveformPlotPoints(waveform), id: \.self) { point in
                    LineMark(x: .value("Time", point.timeMs), y: .value("Brightness", point.brightness))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(palette.accent)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 90)
                .mask(alignment: .leading) {
                    Rectangle().scaleEffect(x: waveformRevealed || !motionEnabled ? 1 : 0, anchor: .leading)
                }
                .onAppear {
                    guard motionEnabled else { return }
                    withAnimation(.easeOut(duration: 1.2)) { waveformRevealed = true }
                }
            }
            .padding(12)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
        }
    }

    /// Three periods so it reads as an oscilloscope trace, not one ambiguous hump.
    private struct WaveformPlotPoint: Hashable {
        let timeMs: Double
        let brightness: Double
    }

    private func waveformPlotPoints(_ waveform: FlickerWaveform) -> [WaveformPlotPoint] {
        let periodMs = 1000.0 / waveform.frequencyHz
        return (0..<3).flatMap { cycle in
            waveform.points.map { point in
                WaveformPlotPoint(
                    timeMs: (Double(cycle) + point.phase) * periodMs,
                    brightness: point.brightness
                )
            }
        }
    }
}
