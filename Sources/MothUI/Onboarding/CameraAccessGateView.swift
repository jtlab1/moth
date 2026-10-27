import MothCapture
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// No skip since the app can't work without the camera. Asking here also stops the view models' prompts racing onboarding.
public struct CameraAccessGateView: View {
    private enum Phase: Equatable {
        case requesting
        case denied
        case restricted
    }

    let onGranted: () -> Void

    @Environment(\.mothPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .requesting

    public init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()

            hero
                .mothAppear()

            Group {
                switch phase {
                case .requesting:
                    requestingContent
                case .denied:
                    deniedContent(restricted: false)
                case .restricted:
                    deniedContent(restricted: true)
                }
            }
            .transition(.mothSwap)
            .mothAppear(delay: 0.08)

            Spacer()
        }
        .padding(MothTheme.sectionSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mothScreenBackground()
        .animation(MothTheme.Motion.smooth, value: phase)
        .task { await requestAccess() }
        .onChange(of: scenePhase) { _, newPhase in
            // Reads the live status: `requestCamera()` only prompts from `.notDetermined`.
            guard newPhase == .active, phase != .requesting else { return }
            apply(CapturePermissions.camera)
        }
    }

    /// Goes still and red once refused: the one at-a-glance "stuck" signal.
    @ViewBuilder
    private var hero: some View {
        if phase == .requesting {
            MothOrb(size: 170, systemImage: "camera.fill")
                .transition(.mothSwap)
        } else {
            MothIconBadge(systemImage: "video.slash.fill", color: palette.danger, size: 96)
                .transition(.mothSwap)
        }
    }

    private var requestingContent: some View {
        VStack(spacing: 12) {
            Text("Moth needs your camera")
                .font(.moth(.title, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
            Text("Moth reads how a light flickers straight off the camera sensor, and that's the only thing it uses the camera for. No photos or video are ever saved.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                Text("Everything stays on this phone")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.accentSoft, in: Capsule())
            .padding(.top, 8)
        }
    }

    private func deniedContent(restricted: Bool) -> some View {
        VStack(spacing: 12) {
            Text("Camera access is off")
                .font(.moth(.title, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
            Text(restricted
                ? "Camera access is restricted on this device, so Moth can't measure anything. Ask whoever manages this device's restrictions to allow it."
                : "Moth can't do anything without camera access. There's no other way it measures flicker. Turn it on for Moth in Settings to continue.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            #if canImport(UIKit)
            if !restricted {
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape.fill")
                }
                .buttonStyle(.mothPrimary)
                .padding(.top, 12)
            }
            #endif
        }
    }

    private func requestAccess() async {
        apply(await CapturePermissions.requestCamera())
    }

    private func apply(_ state: PermissionState) {
        switch state {
        case .granted: onGranted()
        case .denied: phase = .denied
        case .restricted: phase = .restricted
        case .notDetermined: phase = .requesting
        }
    }

    #if canImport(UIKit)
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#Preview("Requesting") {
    CameraAccessGateView(onGranted: {})
        .environment(\.mothPalette, MothTheme.dark)
}
