import MeasurementCore
import MothCapture
import SwiftUI

public struct MeasureView: View {
    @Bindable var viewModel: MeasureViewModel
    let onSaveRoom: (MeasurementDraft, Int?, String) -> Void

    /// Set when measuring from inside a known room, so the name can't be retyped onto another room.
    let presetRoomName: String?

    /// `viewModel` is shared with a sheet and `TabView` keeps hidden tabs alive, so without this
    /// a second preview layer blocked the main thread ~9 s and blacked out the visible one.
    let showsLivePreview: Bool

    @Environment(\.mothPalette) private var palette
    @State private var roomName: String
    @State private var isSaved = false
    #if DEBUG
    @State private var fixtureDumpName = ""
    #endif

    public init(
        viewModel: MeasureViewModel,
        presetRoomName: String? = nil,
        showsLivePreview: Bool = true,
        onSaveRoom: @escaping (MeasurementDraft, Int?, String) -> Void
    ) {
        self.viewModel = viewModel
        self.presetRoomName = presetRoomName
        self.showsLivePreview = showsLivePreview
        self.onSaveRoom = onSaveRoom
        self._roomName = State(initialValue: presetRoomName ?? "")
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: MothTheme.sectionSpacing) {
                heroCard

                if viewModel.phase == .result, let draft = viewModel.draft {
                    FixesSection(rules: Guidance.rules(for: draft.flicker))
                        .transition(resultSectionTransition)
                    ComfortRatingView(rating: $viewModel.comfortRating)
                        .transition(resultSectionTransition)
                    SaveRoomSection(roomName: $roomName, isNameLocked: presetRoomName != nil, isSaved: isSaved) {
                        onSaveRoom(draft, viewModel.comfortRating, roomName)
                        isSaved = true
                    }
                    .transition(resultSectionTransition)
                    Button {
                        viewModel.reset()
                    } label: {
                        Text("Measure again")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(resultSectionTransition)
                }
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: viewModel.phase)
        }
        .scrollDismissesKeyboard(.interactively)
        .mothScreenBackground()
        .sensoryFeedback(.success, trigger: viewModel.phase == .result) { _, isResult in isResult }
        .sensoryFeedback(.impact(weight: .light), trigger: isCapturing) { _, capturing in capturing }
        .onChange(of: viewModel.phase) { _, newPhase in
            if newPhase == .idle {
                roomName = presetRoomName ?? ""
                isSaved = false
            }
        }
    }

    private var resultSectionTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        )
    }

    private var isCapturing: Bool {
        if case .capturing = viewModel.phase { return true }
        return false
    }

    @ViewBuilder
    private var heroCard: some View {
        MothCard {
            VStack(spacing: 16) {
                switch viewModel.phase {
                case .idle, .permissionDenied, .failed:
                    enableCameraContent
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
                case .previewing, .capturing:
                    liveCameraContent
                        .transition(.mothSwap)
                case .analyzing:
                    analyzingContent
                        .transition(.mothSwap)
                case .result:
                    resultContent
                        .transition(.mothSwap)
                }
            }
        }
    }

    private var enableCameraContent: some View {
        VStack(spacing: 14) {
            MothOrb(size: 132, systemImage: "lightbulb")
                .padding(.top, 4)
            Text("Measure the light in this room")
                .font(.moth(.title2, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
            Text("Point the top of your phone at the light, then hold still for a few seconds.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if case .permissionDenied = viewModel.phase {
                errorBanner("Camera access is off. Turn it on for Moth in Settings to measure a room.")
            }
            if case .failed(let message) = viewModel.phase {
                errorBanner(message)
            }

            Button("Start") {
                viewModel.start()
            }
            .buttonStyle(.mothPrimary)
            .padding(.top, 6)

            Text("Uses the camera. Measurements stay on this phone.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(palette.primaryText)
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous))
            .transition(.mothSwap)
    }

    /// One view across `.previewing` and `.capturing` so the preview layer keeps one identity;
    /// separate copies briefly attached a second layer during the transition.
    private var liveCameraContent: some View {
        VStack(spacing: 16) {
            cameraPreview
            if case .capturing(let progress) = viewModel.phase {
                VStack(alignment: .leading, spacing: 12) {
                    if progress.isDim {
                        CaptureQualityWarning(message: "Too dark to measure — move closer to the light or aim more directly at it.")
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Hold still")
                            .font(.moth(.title2, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Text("\(Int((progress.fraction * 100).rounded()))%")
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(palette.secondaryText)
                    }
                    MothProgressBar(value: progress.fraction)
                    Text("You’re doing fine. This takes a few seconds.")
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    Text("Keep the light near the top of the screen, then hold still.")
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    #if DEBUG
                    debugFixtureDumpField
                    #endif
                    Button {
                        #if DEBUG
                        let trimmed = fixtureDumpName.trimmingCharacters(in: .whitespacesAndNewlines)
                        MeasurementRunner.debugPendingDumpName = trimmed.isEmpty ? nil : trimmed
                        #endif
                        viewModel.capture()
                    } label: {
                        Text("Start measuring")
                    }
                    .buttonStyle(.mothPrimary)
                }
                .transition(.opacity)
            }
        }
    }

    private var cameraPreview: some View {
        Group {
            if showsLivePreview {
                MeasureCameraPreview(session: viewModel.previewSession)
            } else {
                Color.black
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay { ViewfinderOverlay(isScanning: isCapturing) }
        .clipShape(RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius - 6, style: .continuous))
    }

    #if DEBUG
    /// Debug-only fixture capture via `DebugFrameDump`.
    private var debugFixtureDumpField: some View {
        TextField("Fixture name (optional, debug builds only)", text: $fixtureDumpName)
            .textFieldStyle(.plain)
            .font(.caption)
            .mothField()
    }
    #endif

    private var analyzingContent: some View {
        VStack(spacing: 18) {
            MothWaveform(cycles: 3, speed: 0.4, lineWidth: 3)
                .frame(height: 70)
            Text("Reading the light…")
                .font(.moth(.title3, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Text("Almost done. You can lower your phone now.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder
    private var resultContent: some View {
        if let draft = viewModel.draft {
            MeasurementResultCard(draft: draft)
        }
    }
}

