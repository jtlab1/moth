import MeasurementCore
import MothCapture
import SwiftUI

public struct CalibrationView: View {
    let viewModel: CalibrationViewModel
    let debugModeEnabled: Bool
    let onCalibrated: (DeviceCalibration) -> Void

    @Environment(\.mothPalette) private var palette

    public init(
        viewModel: CalibrationViewModel,
        debugModeEnabled: Bool = false,
        onCalibrated: @escaping (DeviceCalibration) -> Void
    ) {
        self.viewModel = viewModel
        self.debugModeEnabled = debugModeEnabled
        self.onCalibrated = onCalibrated
    }

    public var body: some View {
        // Animated on the whole VStack: animating only the phase card let `explanationCard`
        // snap into place over the still-shrinking preview.
        ScrollView {
            VStack(spacing: MothTheme.sectionSpacing) {
                stepTracker

                MothCard {
                    VStack(spacing: 16) {
                        switch viewModel.phase {
                        case .choosingMainsRegion:
                            mainsRegionContent
                                .transition(.mothSwap)
                        case .requestingPermission:
                            VStack(spacing: 14) {
                                MothOrb(size: 110, systemImage: "camera.fill")
                                Text("Requesting camera access…")
                                    .font(.subheadline)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .transition(.mothSwap)
                        case .permissionDenied:
                            permissionDeniedContent
                                .transition(.mothSwap)
                        case .previewing, .capturing, .confirming, .solving:
                            liveCameraContent
                                .transition(.mothSwap)
                        case .succeeded(let calibration):
                            succeededContent(calibration)
                                .transition(.mothSwap)
                        case .rejected:
                            rejectedContent
                                .transition(.mothSwap)
                        case .inconsistent:
                            inconsistentContent
                                .transition(.mothSwap)
                        case .failed(let message):
                            problemContent(title: nil, message: message, hint: nil, color: palette.danger)
                                .transition(.mothSwap)
                        }
                    }
                }

                explanationCard

                #if DEBUG
                debugSkipButton
                #endif
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: viewModel.phase)
        }
        .mothScreenBackground()
        .sensoryFeedback(.success, trigger: isSucceededPhase) { _, succeeded in succeeded }
        .sensoryFeedback(.error, trigger: isProblemPhase) { _, problem in problem }
    }

    // MARK: - Step tracker

    private static let stepTitles = ["Region", "Aim", "Capture", "Done"]

    /// Display only; never drives `viewModel.phase`. Failed passes stay on "Capture".
    private var currentStep: Int {
        switch viewModel.phase {
        case .choosingMainsRegion: return 0
        case .requestingPermission, .permissionDenied, .previewing: return 1
        case .capturing, .solving, .confirming, .rejected, .inconsistent, .failed: return 2
        case .succeeded: return 3
        }
    }

    private var isSucceededPhase: Bool {
        if case .succeeded = viewModel.phase { return true }
        return false
    }

    private var isProblemPhase: Bool {
        switch viewModel.phase {
        case .rejected, .inconsistent, .failed, .permissionDenied: return true
        default: return false
        }
    }

    private var stepTracker: some View {
        HStack(spacing: 6) {
            ForEach(Self.stepTitles.indices, id: \.self) { index in
                let isDone = index < currentStep || (index == currentStep && isSucceededPhase)
                let isCurrent = index == currentStep && !isSucceededPhase
                VStack(spacing: 8) {
                    Capsule()
                        .fill(isDone || isCurrent ? palette.accent : palette.divider)
                        .frame(height: 5)
                        .shadow(color: isCurrent ? palette.accent.opacity(0.6) : .clear, radius: 5)
                    Text(Self.stepTitles[index])
                        .font(.caption2.weight(isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? palette.primaryText : palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(MothTheme.Motion.smooth, value: currentStep)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(currentStep + 1) of \(Self.stepTitles.count): \(Self.stepTitles[currentStep])"))
    }

    #if DEBUG
    /// Debug-only skip for testing without a fixture or camera; needs a mains region.
    @ViewBuilder
    private var debugSkipButton: some View {
        if !isSucceeded {
            Button("Skip Calibration (DEBUG)") { viewModel.skipForTesting() }
                .font(.footnote)
                .foregroundStyle(palette.warning)
                .disabled(viewModel.mainsRegion == nil)
        }
    }

    private var isSucceeded: Bool {
        if case .succeeded = viewModel.phase { return true }
        return false
    }
    #endif

    private var mainsRegionContent: some View {
        VStack(spacing: 16) {
            MothIconBadge(systemImage: "bolt.fill", size: 64)
            Text("Where is this phone?")
                .font(.moth(.title2))
                .foregroundStyle(palette.primaryText)
            Text("This sets the reference flicker frequency the calibration checks against.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                ForEach(MainsRegion.allCases) { region in
                    let isSelected = viewModel.mainsRegion == region
                    Button {
                        viewModel.mainsRegion = region
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(region.title).font(.moth(.headline, weight: .semibold))
                                Text(region.subtitle).font(.caption)
                                    .opacity(0.85)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .foregroundStyle(isSelected ? palette.onAccent : palette.primaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.accentSoft),
                            in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
                    }
                    .buttonStyle(.mothPressable)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .animation(MothTheme.Motion.snappy, value: viewModel.mainsRegion)
            .sensoryFeedback(.selection, trigger: viewModel.mainsRegion)

            Button("Continue") { viewModel.confirmMainsRegion() }
                .buttonStyle(.mothPrimary)
                .disabled(viewModel.mainsRegion == nil)
        }
    }

    private var permissionDeniedContent: some View {
        VStack(spacing: 12) {
            MothIconBadge(systemImage: "video.slash.fill", color: palette.danger, size: 64)
            Text("Camera access is off. Turn it on for Moth in Settings to calibrate.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// One view across every camera phase so the preview layer keeps one identity (see
    /// `MeasureView.showsLivePreview`). `.solving` keeps it since the confirming pass follows.
    private var liveCameraContent: some View {
        VStack(spacing: 16) {
            MeasureCameraPreview(session: viewModel.previewSession)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { ViewfinderOverlay(isScanning: isScanning) }
                .clipShape(RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            switch viewModel.phase {
            case .capturing(let progress):
                captureProgressContent(progress: progress, isConfirming: false)
            case .confirming(let progress):
                captureProgressContent(progress: progress, isConfirming: true)
            case .solving:
                VStack(spacing: 10) {
                    MothWaveform(cycles: 3, speed: 1.2)
                        .frame(height: 40)
                    Text("Solving…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .transition(.opacity)
            default:
                VStack(spacing: 10) {
                    Label("Aim at an older fluorescent tube or an incandescent bulb — not an LED — and hold still.", systemImage: "lightbulb.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.leading)
                    Text("Moth captures twice and checks the two readings agree, so keep holding still until it's done.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        viewModel.capture()
                    } label: {
                        Label("Start Calibration", systemImage: "scope")
                    }
                    .buttonStyle(.mothPrimary)
                    .padding(.top, 4)
                }
                .transition(.opacity)
            }
        }
    }

    private var isScanning: Bool {
        switch viewModel.phase {
        case .capturing, .confirming: return true
        default: return false
        }
    }

    @ViewBuilder
    private func captureProgressContent(progress: CaptureProgress, isConfirming: Bool) -> some View {
        VStack(spacing: 12) {
            if progress.isDim {
                CaptureQualityWarning(message: "Too dark to calibrate — aim more directly at the reference fixture.")
            }
            MothProgressBar(value: progress.fraction)
            HStack {
                Text(isConfirming ? "Hold still — confirming…" : "Hold still — calibrating…")
                Spacer()
                Text(isConfirming ? "Pass 2 of 2" : "Pass 1 of 2")
                    .foregroundStyle(palette.accent)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(palette.secondaryText)
        }
        .transition(.opacity)
    }

    private func succeededContent(_ calibration: DeviceCalibration) -> some View {
        VStack(spacing: 14) {
            CalibrationSuccessMark()
                .padding(.vertical, 8)
            Text("Calibrated")
                .font(.moth(.title2))
                .foregroundStyle(palette.primaryText)
            Text("Moth is ready to measure on this phone.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            if debugModeEnabled {
                Text(calibration.formattedLineReadoutTime)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }
            Button("Done") { onCalibrated(calibration) }
                .buttonStyle(.mothPrimary)
                .padding(.top, 4)
        }
    }

    private var rejectedContent: some View {
        problemContent(
            title: "That didn't look right",
            message: "Calibration produced a result outside the physically plausible range, so it wasn't saved.",
            hint: "Try again using an older fluorescent or incandescent fixture, not an LED.",
            color: palette.warning
        )
    }

    private var inconsistentContent: some View {
        problemContent(
            title: "The two readings didn't match",
            message: "Moth calibrates twice to be sure. This time the two readings disagreed, so neither was saved.",
            hint: "Try again, holding the phone as still as possible and keeping the reference fixture centred the whole time.",
            color: palette.warning
        )
    }

    private func problemContent(title: String?, message: String, hint: String?, color: Color) -> some View {
        VStack(spacing: 12) {
            MothIconBadge(systemImage: "exclamationmark.triangle.fill", color: color, size: 64)
            if let title {
                Text(title)
                    .font(.moth(.title3))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Button {
                viewModel.retry()
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.mothPrimary)
            .padding(.top, 4)
        }
    }

    private var explanationCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 10) {
                MothSectionHeader("Why this is needed")
                Text("This is the one number that turns image rows into elapsed time. Without it, Moth can tell you whether a light is flickering but not how fast.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }
}

private struct CalibrationSuccessMark: View {
    @Environment(\.mothPalette) private var palette
    @State private var isShown = false

    var body: some View {
        ZStack {
            Circle()
                .fill(palette.success.opacity(0.18))
                .scaleEffect(isShown ? 1.5 : 0.6)
                .opacity(isShown ? 0 : 1)
                .animation(.easeOut(duration: 0.9).delay(0.5), value: isShown)
            Circle()
                .trim(from: 0, to: isShown ? 1 : 0)
                .stroke(palette.success, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.55), value: isShown)
            Image(systemName: "checkmark")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(palette.success)
                .scaleEffect(isShown ? 1 : 0.2)
                .opacity(isShown ? 1 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.45), value: isShown)
        }
        .frame(width: 88, height: 88)
        .onAppear { isShown = true }
        .accessibilityHidden(true)
    }
}
