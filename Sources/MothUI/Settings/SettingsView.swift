import MeasurementCore
import MothCapture
import SwiftUI

public struct SettingsView: View {
    @Binding var settings: UserSettings
    let calibrationState: CalibrationState
    let onRecalibrate: () -> Void
    let onResetCalibration: () -> Void
    /// Debug only.
    let onForgetEverything: () -> Void

    @Environment(\.mothPalette) private var palette
    @State private var showingResetConfirmation = false
    @State private var showingTerms = false
    @State private var showingForgetConfirmation = false

    public init(
        settings: Binding<UserSettings>,
        calibrationState: CalibrationState,
        onRecalibrate: @escaping () -> Void,
        onResetCalibration: @escaping () -> Void,
        onForgetEverything: @escaping () -> Void
    ) {
        self._settings = settings
        self.calibrationState = calibrationState
        self.onRecalibrate = onRecalibrate
        self.onResetCalibration = onResetCalibration
        self.onForgetEverything = onForgetEverything
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: MothTheme.sectionSpacing) {
                mainsRegionCard.mothAppear()
                appearanceCard.mothAppear(delay: 0.04)
                motionCard.mothAppear(delay: 0.08)
                calibrationCard.mothAppear(delay: 0.12)
                privacyCard.mothAppear(delay: 0.16)
                aboutCard.mothAppear(delay: 0.2)
                debugCard.mothAppear(delay: 0.24)
            }
            .padding(MothTheme.sectionSpacing)
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
        #if DEBUG
        .sheet(isPresented: $showingForgetConfirmation) {
            NavigationStack {
                ForgetEverythingScreen {
                    showingForgetConfirmation = false
                    onForgetEverything()
                }
                .mothCenteredTitle("Forget Everything")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingForgetConfirmation = false }
                    }
                }
            }
        }
        #endif
        .sheet(isPresented: $showingResetConfirmation) {
            NavigationStack {
                ResetCalibrationScreen {
                    onResetCalibration()
                    showingResetConfirmation = false
                }
                .mothCenteredTitle("Reset Calibration")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingResetConfirmation = false }
                    }
                }
            }
        }
    }

    private var mainsRegionCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 12) {
                MothSectionHeader(
                    "Mains power frequency",
                    subtitle: "Sets the known frequency of the reference light used to calibrate this phone. Changing it after calibrating means recalibrating."
                )
                HStack {
                    Text(settings.mainsRegion?.subtitle ?? "Not set")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Picker("Mains power frequency", selection: $settings.mainsRegion) {
                        Text("Not set").tag(MainsRegion?.none)
                        ForEach(MainsRegion.allCases) { region in
                            Text(region.title).tag(MainsRegion?.some(region))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(palette.accent)
                    .labelsHidden()
                }
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            }
            .foregroundStyle(palette.primaryText)
        }
    }

    /// Animated through the binding so the app crossfades between palettes.
    private var appearanceCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 12) {
                MothSectionHeader("Appearance")
                Picker("Appearance", selection: $settings.appearance.animation(.easeInOut(duration: 0.35))) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    /// The footnote mentions Reduce Motion so the switch never seems ignored.
    private var motionCard: some View {
        MothCard {
            Toggle(isOn: $settings.animationsEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Animations")
                        .font(.moth(.title3, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(settings.animationsEnabled
                         ? "Gentle ripples and fades. Reduce Motion on your iPhone also turns these off."
                         : "Everything stays still.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(palette.accent)
        }
    }

    private var calibrationCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    MothSectionHeader("Calibration")
                    Image(systemName: calibrationStatusSymbol)
                        .font(.title3)
                        .foregroundStyle(calibrationState.isCalibrated ? palette.success : palette.warning)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                Text(calibrationStatusText)
                    .font(calibrationState.isOutdated ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(calibrationState.isOutdated ? palette.primaryText : palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onRecalibrate()
                } label: {
                    Label(calibrationState.isCalibrated || calibrationState.isOutdated ? "Recalibrate" : "Calibrate", systemImage: "scope")
                }
                .buttonStyle(.mothPrimary)
                if calibrationState.isCalibrated {
                    Button("Reset Calibration") { showingResetConfirmation = true }
                        .buttonStyle(.mothDestructive)
                        .transition(.mothSwap)
                }
            }
            .animation(MothTheme.Motion.smooth, value: calibrationState.isCalibrated)
        }
    }

    private var calibrationStatusSymbol: String {
        if calibrationState.isCalibrated { return "checkmark.circle" }
        if calibrationState.isOutdated { return "arrow.triangle.2.circlepath" }
        return "exclamationmark.circle"
    }

    private var calibrationStatusText: String {
        switch calibrationState {
        case .uncalibrated:
            return "Not calibrated yet. Moth can tell you whether a light is flickering but not how fast."
        case .calibrated(let calibration):
            let summary = calibration.responseCurve != nil
                ? "Calibrated for full measurement: frequency, depth and the IEEE 1789 verdict."
                : "Calibrated for frequency. The light-response step didn’t finish, so depth isn’t available. Recalibrate to try it again."
            guard settings.debugModeEnabled else { return summary }
            return "\(summary) \(calibration.formattedLineReadoutTime), \(calibration.format.formattedDimensions)."
        case .foreignDevice:
            return "A calibration exists but was solved on different hardware. Recalibrate on this phone."
        case .outdated:
            return RecalibrationBanner.message
        case .rejected:
            return "The last calibration attempt was rejected as implausible. Try again."
        }
    }

    private var privacyCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 10) {
                MothSectionHeader("Privacy")
                Text(PermissionUsageStrings.cameraValue)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                Text("All measurements stay on this device. Moth has no accounts, no backend, and no networking.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private var aboutCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    MothOrb(size: 44, isAnimating: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moth")
                            .font(.moth(.headline, weight: .heavy))
                            .foregroundStyle(palette.primaryText)
                        Text("Moth \(DeviceIdentity.appVersion)")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Text("Measures how a room's lighting flickers against IEEE 1789, to help find rooms that are hard on sensory-sensitive people.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                Text(TermsView.shortNotice)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                Button("Terms & Disclaimer") { showingTerms = true }
                    .buttonStyle(.mothSecondary)
                    .padding(.top, 4)
            }
        }
    }

    private var debugCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 14) {
                debugToggle
                #if DEBUG
                if settings.debugModeEnabled {
                    Button("Forget Everything") { showingForgetConfirmation = true }
                        .buttonStyle(.mothDestructive)
                        .transition(.mothSwap)
                }
                #endif
            }
        }
    }

    private var debugToggle: some View {
        Toggle(isOn: $settings.debugModeEnabled.animation(MothTheme.Motion.smooth)) {
            HStack(spacing: 12) {
                MothIconBadge(systemImage: "ladybug.fill", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug mode")
                        .font(.moth(.headline))
                    Text("Shows technical calibration detail, like the raw line readout time, that isn't meaningful to most people.")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .tint(palette.accent)
        .foregroundStyle(palette.primaryText)
    }
}

#if DEBUG
/// Debug only, for demoing first run without reinstalling.
private struct ForgetEverythingScreen: View {
    let onConfirm: () -> Void

    @Environment(\.mothPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: MothTheme.sectionSpacing) {
                MothCard {
                    VStack(spacing: 14) {
                        MothIconBadge(systemImage: "exclamationmark.triangle.fill", color: palette.danger, size: 72)
                        Text("Forget everything?")
                            .font(.moth(.title2))
                            .foregroundStyle(palette.primaryText)
                        Text("Erases all rooms, buildings, measurements, calibrations, your own coping strategies, and settings, then starts over from onboarding. This can't be undone.")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                        Text("Camera permission is controlled by iOS, so it stays granted.")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Forget Everything", action: onConfirm)
                            .buttonStyle(.mothDestructive)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .mothAppear()
            }
            .padding(MothTheme.sectionSpacing)
        }
        .mothScreenBackground()
    }
}
#endif

/// A themed sheet, matching where calibration appears, instead of an unthemed system dialog.
private struct ResetCalibrationScreen: View {
    let onConfirm: () -> Void

    @Environment(\.mothPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: MothTheme.sectionSpacing) {
                MothCard {
                    VStack(spacing: 14) {
                        MothIconBadge(systemImage: "exclamationmark.triangle.fill", color: palette.warning, size: 72)
                        Text("Reset calibration?")
                            .font(.moth(.title2))
                            .foregroundStyle(palette.primaryText)
                        Text("This phone will need to calibrate again before it can measure. Rooms and past measurements are not affected.")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Reset Calibration", action: onConfirm)
                            .buttonStyle(.mothDestructive)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .mothAppear()
            }
            .padding(MothTheme.sectionSpacing)
        }
        .mothScreenBackground()
    }
}
