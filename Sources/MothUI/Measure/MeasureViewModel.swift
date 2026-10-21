import AVFoundation
import Foundation
import MeasurementCore
import Observation
import MothCapture

@MainActor
@Observable
public final class MeasureViewModel {
    public enum Phase: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case previewing
        case capturing(CaptureProgress)
        case analyzing
        case result
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var draft: MeasurementDraft?
    public var comfortRating: Int?

    private let runner: MeasurementRunner
    private let calibrationProvider: () -> DeviceCalibration?
    private var calibration: DeviceCalibration? { calibrationProvider() }

    /// Started in `init` so camera setup finishes while the app is still launching.
    private var prepareTask: Task<Void, Error>?

    /// Bumped by `reset()`; async work captured before a reset writes nothing, so a late
    /// capture can't surface a savable result in the next room's sheet.
    private var generation = 0
    private var captureTask: Task<Void, Never>?

    /// A closure so a change on the Calibration screen applies to the very next capture.
    public init(
        runner: MeasurementRunner,
        calibration: @escaping () -> DeviceCalibration?
    ) {
        self.runner = runner
        self.calibrationProvider = calibration
        beginPreparingCamera()
    }

    public nonisolated var previewSession: AVCaptureSession { runner.previewSession }

    public func start() {
        switch phase {
        case .idle, .permissionDenied, .failed:
            Task { await requestAndPreview() }
        default:
            break
        }
    }

    /// Memoized so the `init` warm-up and a later call share one attempt instead of racing.
    @discardableResult
    private func beginPreparingCamera() -> Task<Void, Error> {
        if let prepareTask { return prepareTask }
        let task = Task {
            let cameraState = await CapturePermissions.requestCamera()
            guard cameraState == .granted else {
                throw CaptureSetupError.cameraPermissionMissing
            }
            try await runner.prepare()
        }
        prepareTask = task
        return task
    }

    private func requestAndPreview() async {
        let generation = self.generation
        phase = .requestingPermission
        do {
            try await beginPreparingCamera().value
        } catch CaptureSetupError.cameraPermissionMissing {
            prepareTask = nil
            if generation == self.generation { phase = .permissionDenied }
            return
        } catch {
            prepareTask = nil
            if generation == self.generation {
                phase = .failed(Self.message(for: error, fallback: "Couldn't start the camera."))
            }
            return
        }
        guard generation == self.generation else { return }
        await runner.startPreview()
        guard generation == self.generation else { return }
        phase = .previewing
    }

    public func capture() {
        guard phase == .previewing else { return }
        captureTask = Task { await runCapture() }
    }

    private func runCapture() async {
        let generation = self.generation
        phase = .capturing(CaptureProgress(framesCaptured: 0, elapsed: 0, duration: MeasurementRunner.captureDuration))
        do {
            let result = try await runner.measure(
                calibration: calibration,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == generation, case .capturing = self.phase else { return }
                        self.phase = progress.fraction >= 1 ? .analyzing : .capturing(progress)
                    }
                }
            )
            guard generation == self.generation else { return }
            draft = result
            comfortRating = nil
            phase = .result
        } catch {
            guard generation == self.generation else { return }
            phase = .failed(Self.message(for: error, fallback: "Measurement failed."))
        }
    }

    /// Clears state synchronously so nothing stale renders even for a frame: this view model
    /// is shared across every room's sheet.
    public func reset() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        draft = nil
        comfortRating = nil
        phase = .idle
        Task { await runner.stopPreview() }
    }

    private static func message(for error: Error, fallback: String) -> String {
        guard let localized = error as? LocalizedError, let description = localized.errorDescription else {
            return fallback
        }
        guard let suggestion = localized.recoverySuggestion else { return description }
        return "\(description) \(suggestion)"
    }
}

#if DEBUG
extension MeasureViewModel {
    public func previewSeed(phase: Phase, draft: MeasurementDraft? = nil) {
        self.phase = phase
        self.draft = draft
    }
}
#endif
