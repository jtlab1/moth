import MeasurementCore
import MothCapture
import SwiftUI

public struct CalibrationView: View {
    let viewModel: CalibrationViewModel
    let debugModeEnabled: Bool
    /// Called with a frequency-only calibration too, when the user keeps one.
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
        // Animate the whole VStack; animating just the phase card made `explanationCard` snap over the shrinking preview.
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
                        case .previewing, .readout, .solving, .measuringResponse:
                            liveCameraContent
                                .transition(.mothSwap)
                        case .succeeded(let outcome):
                            succeededContent(outcome)
                                .transition(.mothSwap)
                        case .rejected:
                            rejectedContent
                                .transition(.mothSwap)
                        case .inconsistent:
                            inconsistentContent
                                .transition(.mothSwap)
                        case .failed(let message, let hint, let detail):
                            problemContent(
                                title: nil,
                                message: message,
                                hint: hint,
                                detail: debugModeEnabled ? detail : nil,
                                color: palette.danger
                            )
                                .transition(.mothSwap)
                        }
                    }
                }

                explanationCard
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: viewModel.phase)
        }
        .onChange(of: viewModel.phase, initial: true) { _, phase in
            switch phase {
            case .measuringResponse: isSolvingResponse = true
            case .solving: break
            default: isSolvingResponse = false
            }
        }
        .mothScreenBackground()
        .sensoryFeedback(.success, trigger: isSucceededPhase) { _, succeeded in succeeded }
        .sensoryFeedback(.error, trigger: isProblemPhase) { _, problem in problem }
    }

    // MARK: - Step tracker

    private static let stepTitles = ["Region", "Aim", "Capture", "Light", "Done"]

    /// Display only; never drives `viewModel.phase`. Failed passes stay on "Capture".
    private var currentStep: Int {
        switch viewModel.phase {
        case .choosingMainsRegion: return 0
        case .requestingPermission, .permissionDenied, .previewing: return 1
        case .readout, .rejected, .inconsistent, .failed: return 2
        case .solving: return isSolvingResponse ? 3 : 2
        case .measuringResponse: return 3
        case .succeeded: return 4
        }
    }

    /// `.solving` follows both readout passes and the sweep; after the sweep it stays on "Light".
    @State private var isSolvingResponse = false

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

    /// One view across all camera phases so the preview layer keeps its identity (see `MeasureView.showsLivePreview`).
    private var liveCameraContent: some View {
        VStack(spacing: 16) {
            MeasureCameraPreview(session: viewModel.previewSession)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { ViewfinderOverlay(isScanning: isScanning) }
                .clipShape(RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            switch viewModel.phase {
            case .readout(let pass, let progress):
                readoutProgressContent(pass: pass, progress: progress)
            case .measuringResponse(let progress):
                responseProgressContent(progress)
            case .solving:
                VStack(spacing: 10) {
                    MothWaveform(cycles: 3, speed: 1.2)
                        .frame(height: 40)
                        .accessibilityHidden(true)
                    Text(isSolvingResponse ? "Working out how your camera responds to light…" : "Solving…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    cancelButton
                }
                .transition(.opacity)
            default:
                VStack(spacing: 10) {
                    Label("Aim at an older fluorescent tube or an incandescent bulb (not an LED) and hold still.", systemImage: "lightbulb.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.leading)
                    Text("Moth captures twice and checks the two readings agree, then takes a few short captures to learn how your camera responds to light. Keep holding still until it’s done, about twenty seconds.")
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
        case .readout, .measuringResponse: return true
        default: return false
        }
    }

    /// Stops the capture without leaving the screen; the sheet's Close does the same.
    private var cancelButton: some View {
        Button("Cancel") { viewModel.cancel() }
            .font(.body.weight(.semibold))
            .foregroundStyle(palette.accent)
            .frame(minHeight: 44)
            .accessibilityHint(Text("Stops calibrating. Nothing new is saved."))
    }

    @ViewBuilder
    private func readoutProgressContent(pass: Int, progress: CaptureProgress) -> some View {
        let passCount = MeasurementRunner.readoutPassCount
        VStack(spacing: 12) {
            if progress.isDim {
                CaptureQualityWarning(message: "Too dark to calibrate. Aim more directly at the reference fixture.")
            }
            MothProgressBar(value: progress.fraction)
            HStack {
                Text(pass > 1 ? "Hold still, confirming…" : "Hold still, calibrating…")
                Spacer()
                Text("Pass \(pass) of \(passCount)")
                    .foregroundStyle(palette.accent)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(palette.secondaryText)
            .accessibilityElement(children: .combine)
            cancelButton
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func responseProgressContent(_ progress: ResponseSweepProgress) -> some View {
        VStack(spacing: 12) {
            if progress.isDim {
                CaptureQualityWarning(message: "Too dark to read the light. Keep aiming at the same fixture as before.")
            }
            MothProgressBar(value: progress.fraction)
            HStack(alignment: .firstTextBaseline) {
                Text("Hold still, measuring how your camera responds to light")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("Step \(progress.step) of \(progress.stepCount)")
                    .foregroundStyle(palette.accent)
                    .monospacedDigit()
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(palette.secondaryText)
            .accessibilityElement(children: .combine)
            Text("The picture may get brighter or darker between steps. That’s expected. Resting the phone against something helps.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            cancelButton
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func succeededContent(_ outcome: CalibrationOutcome) -> some View {
        if outcome.usesAssumedResponse {
            assumedResponseContent(outcome)
        } else if outcome.unlocksDepth {
            fullySucceededContent(outcome.calibration)
        } else {
            frequencyOnlyContent(outcome)
        }
    }

    private func fullySucceededContent(_ calibration: DeviceCalibration) -> some View {
        VStack(spacing: 14) {
            CalibrationSuccessMark()
                .padding(.vertical, 8)
            Text("Calibrated")
                .font(.moth(.title2))
                .foregroundStyle(palette.primaryText)
            Text("Full measurement is unlocked. Moth can measure how fast a light flickers, how deep the flicker is, and compare both with the IEEE 1789 guideline.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            debugReadout(calibration)
            Button("Done") { onCalibrated(calibration) }
                .buttonStyle(.mothPrimary)
                .padding(.top, 4)
        }
    }

    /// Calibrated with the standard light response. Everything works, depth is a bit less precise, retry is optional.
    private func assumedResponseContent(_ outcome: CalibrationOutcome) -> some View {
        VStack(spacing: 14) {
            CalibrationSuccessMark()
                .padding(.vertical, 8)
            Text("Calibrated")
                .font(.moth(.title2))
                .foregroundStyle(palette.primaryText)
            Text("Full measurement is unlocked. Moth couldn’t measure how your camera responds to light, so it’s using the standard response instead. Depth readings may be a little less precise.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if debugModeEnabled, let reason = outcome.responseCurveFailure {
                Text("Light response: \(reason)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            debugReadout(outcome.calibration)
            Button("Done") { onCalibrated(outcome.calibration) }
                .buttonStyle(.mothPrimary)
                .padding(.top, 4)
            Button {
                viewModel.retryResponseSweep()
            } label: {
                Label("Try measuring the light response again", systemImage: "arrow.counterclockwise")
            }
            .font(.subheadline)
        }
    }

    /// The readout passes agreed, so frequency works; only the sweep is retried.
    private func frequencyOnlyContent(_ outcome: CalibrationOutcome) -> some View {
        VStack(spacing: 14) {
            MothIconBadge(systemImage: "waveform.path", size: 64)
                .padding(.vertical, 8)
            Text("Calibrated for frequency")
                .font(.moth(.title2))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
            Text("Moth can now measure how fast a light flickers. It couldn’t finish learning how your camera responds to light, so flicker depth and the IEEE 1789 verdict aren’t available yet.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Trying that step again usually works. Keep aiming at the same steady light and hold still.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if debugModeEnabled, let reason = outcome.responseCurveFailure {
                Text("Light response: \(reason)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            debugReadout(outcome.calibration)
            Button {
                viewModel.retryResponseSweep()
            } label: {
                Label("Try the light-response step again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.mothPrimary)
            .padding(.top, 4)
            Button("Keep frequency-only calibration") { onCalibrated(outcome.calibration) }
                .buttonStyle(.mothSecondary)
        }
    }

    @ViewBuilder
    private func debugReadout(_ calibration: DeviceCalibration) -> some View {
        if debugModeEnabled {
            Text("\(calibration.formattedLineReadoutTime) · \(calibration.format.formattedDimensions)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(palette.secondaryText)
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

    private func problemContent(title: String?, message: String, hint: String?, detail: String? = nil, color: Color) -> some View {
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
            if let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
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
                Text("Calibration learns two things about this phone’s camera. How fast it reads each line of the picture turns rows into time, so Moth can tell how fast a light flickers. How its brightness readings respond to light lets Moth tell how deep the flicker is.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Without calibration, Moth can only tell you whether a light is flickering.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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
