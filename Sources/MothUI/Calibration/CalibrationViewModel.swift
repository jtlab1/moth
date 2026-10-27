import AVFoundation
import Foundation
import MeasurementCore
import Observation
import MothCapture

@MainActor
@Observable
public final class CalibrationViewModel {
    public enum Phase: Equatable {
        case choosingMainsRegion
        case requestingPermission
        case permissionDenied
        case previewing

        /// Readout pass `pass` of `MeasurementRunner.readoutPassCount`.
        case readout(pass: Int, progress: CaptureProgress)
        case solving

        /// The ISO sweep that measures how the camera responds to light.
        case measuringResponse(ResponseSweepProgress)

        /// Always usable; `responseCurveFailure` says if the light response had to be assumed.
        case succeeded(CalibrationOutcome)
        case rejected(solved: TimeInterval, plausible: ClosedRange<TimeInterval>)
        /// Two plausible solves disagreed (vs `.rejected`, where one was implausible).
        case inconsistent(first: TimeInterval, second: TimeInterval)
        /// `detail` is the technical reason, shown only in debug mode.
        case failed(message: String, hint: String?, detail: String?)

        /// Camera work is in flight, so `cancel()` has something to stop.
        public var isRunning: Bool {
            switch self {
            case .readout, .solving, .measuringResponse: return true
            default: return false
            }
        }
    }

    public private(set) var phase: Phase
    public var mainsRegion: MainsRegion?

    private let runner: MeasurementRunner
    private let captureDuration: TimeInterval

    /// Bumped by `cancel()` so late progress callbacks can't pull the screen back into a stopped capture.
    private var generation = 0
    private var workTask: Task<Void, Never>?

    /// Set during `retryResponseSweep()` so cancelling doesn't throw away a calibration that already works for frequency.
    private var sweepRetryFallback: CalibrationOutcome?

    /// Kicked off in `init` so camera setup finishes while the user reads the picker instead of freezing after the tap.
    private var prepareTask: Task<Void, Error>?

    public init(runner: MeasurementRunner, initialMainsRegion: MainsRegion?, captureDuration: TimeInterval = 4) {
        self.runner = runner
        self.mainsRegion = initialMainsRegion
        self.captureDuration = captureDuration
        self.phase = initialMainsRegion == nil ? .choosingMainsRegion : .requestingPermission
        beginPreparingCamera()
        if initialMainsRegion != nil {
            Task { await requestAndPreview() }
        }
    }

    public nonisolated var previewSession: AVCaptureSession { runner.previewSession }

    public func confirmMainsRegion() {
        guard mainsRegion != nil else { return }
        Task { await requestAndPreview() }
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
        phase = .requestingPermission
        do {
            try await beginPreparingCamera().value
        } catch CaptureSetupError.cameraPermissionMissing {
            phase = .permissionDenied
            prepareTask = nil
            return
        } catch {
            phase = Self.failure(for: error, fallback: "Couldn't start the camera.")
            prepareTask = nil
            return
        }
        await runner.startPreview()
        phase = .previewing
    }

    /// Two captures have to agree before we trust either, then the sweep runs.
    /// The sweep never fails calibration, it just withholds depth.
    public func capture() {
        guard phase == .previewing, let mainsRegion else { return }
        sweepRetryFallback = nil
        let hz = mainsRegion.referenceFlickerFrequencyHz
        // Leave `.previewing` right away so a second tap can't start another calibration.
        phase = .readout(pass: 1, progress: CaptureProgress(framesCaptured: 0, elapsed: 0, duration: captureDuration))
        workTask = Task { await runCalibration(referenceFrequencyHz: hz) }
    }

    /// Re-runs only the sweep, keeping the readout time both passes already agreed on.
    public func retryResponseSweep() {
        guard case .succeeded(let outcome) = phase, !outcome.unlocksDepth || outcome.usesAssumedResponse else { return }
        sweepRetryFallback = outcome
        let readout = outcome.calibration
        // Leave `.succeeded` right away so a second tap can't start another sweep.
        phase = .measuringResponse(ResponseSweepProgress(
            step: 1,
            stepCount: CaptureStandard.responseSweepSteps,
            capture: CaptureProgress(framesCaptured: 0, elapsed: 0, duration: CaptureStandard.responseSweepStepDuration)
        ))
        workTask = Task { await runResponseSweep(for: readout, generation: generation) }
    }

    /// Stops any running capture or solve. A retried sweep falls back to its frequency-only calibration,
    /// anything else goes back to aiming. No-op when idle, so closing a finished screen keeps its result.
    public func cancel() {
        guard phase.isRunning else { return }
        generation += 1
        workTask?.cancel()
        workTask = nil
        if let fallback = sweepRetryFallback {
            sweepRetryFallback = nil
            phase = .succeeded(fallback)
            return
        }
        phase = .previewing
        Task { await runner.startPreview() }
    }

    private func runCalibration(referenceFrequencyHz: Double) async {
        let generation = self.generation
        var firstSolve: TimeInterval?
        var agreed: DeviceCalibration?
        do {
            for pass in 1...MeasurementRunner.readoutPassCount {
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                phase = .readout(pass: pass, progress: CaptureProgress(framesCaptured: 0, elapsed: 0, duration: captureDuration))
                let calibration = try await runner.calibrateReadout(
                    referenceFrequencyHz: referenceFrequencyHz,
                    duration: captureDuration,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.applyReadoutProgress(progress, pass: pass, generation: generation)
                        }
                    }
                )
                guard generation == self.generation else { return }
                if let firstSolve {
                    guard DeviceCalibration.agree(firstSolve, calibration.lineReadoutTime) else {
                        phase = .inconsistent(first: firstSolve, second: calibration.lineReadoutTime)
                        return
                    }
                } else {
                    firstSolve = calibration.lineReadoutTime
                }
                agreed = calibration
            }
        } catch let AnalysisError.implausibleCalibration(solved, plausible) {
            guard generation == self.generation else { return }
            phase = .rejected(solved: solved, plausible: plausible)
            return
        } catch {
            // Cancelled without `cancel()` bumping `generation` means something else stopped the camera.
            // Say so instead of sitting in a capture phase that'll never advance.
            guard generation == self.generation else { return }
            phase = Self.failure(for: error, fallback: "Calibration failed.")
            return
        }
        guard let agreed else { return }
        await runResponseSweep(for: agreed, generation: generation)
    }

    private func runResponseSweep(for readout: DeviceCalibration, generation: Int) async {
        guard generation == self.generation else { return }
        phase = .measuringResponse(ResponseSweepProgress(
            step: 1,
            stepCount: CaptureStandard.responseSweepSteps,
            capture: CaptureProgress(framesCaptured: 0, elapsed: 0, duration: CaptureStandard.responseSweepStepDuration)
        ))
        do {
            let outcome = try await runner.measureResponseCurve(
                for: readout,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.applySweepProgress(progress, generation: generation)
                    }
                }
            )
            guard generation == self.generation else { return }
            sweepRetryFallback = nil
            phase = .succeeded(outcome)
        } catch {
            // Only cancellation gets here. If it wasn't the user, the camera was stopped under us,
            // and the agreed readout time still stands, just without depth.
            guard generation == self.generation else { return }
            if Self.isCancellation(error) {
                sweepRetryFallback = nil
                phase = .succeeded(CalibrationOutcome(
                    calibration: readout.withResponseCurve(.standardSRGB),
                    responseCurveFailure: "The camera stopped before Moth finished measuring how it responds to light."
                ))
                return
            }
            phase = Self.failure(for: error, fallback: "Calibration failed.")
        }
    }

    /// Ignores progress from a pass that's no longer on screen.
    private func applyReadoutProgress(_ progress: CaptureProgress, pass: Int, generation: Int) {
        guard generation == self.generation, case .readout(let shownPass, _) = phase, shownPass == pass else { return }
        phase = progress.fraction >= 1 ? .solving : .readout(pass: pass, progress: progress)
    }

    private func applySweepProgress(_ progress: ResponseSweepProgress, generation: Int) {
        guard generation == self.generation, case .measuringResponse = phase else { return }
        phase = progress.fraction >= 1 ? .solving : .measuringResponse(progress)
    }

    /// Restarts the preview, because `MeasureViewModel.reset()` stops the shared session.
    public func retry() {
        generation += 1
        sweepRetryFallback = nil
        workTask?.cancel()
        workTask = nil
        Task {
            await runner.startPreview()
            phase = .previewing
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let analysis = error as? AnalysisError, analysis == .cancelled { return true }
        return false
    }

    /// The plain message, what to try next, and the debug reason, since "not enough signal" and "no flicker" need different fixes.
    private static func failure(for error: Error, fallback: String) -> Phase {
        let localized = error as? LocalizedError
        var detail: String?
        switch error as? AnalysisError {
        case .insufficientSignal(let reason)?, .referenceFlickerNotFound(let reason)?,
             .responseCurveUnsolvable(let reason)?:
            detail = reason
        case .frameRateLockedToLight(let frameRate, let lightHz)?:
            detail = String(format: "measured %.2f fps against a %.0f Hz reference", frameRate, lightHz)
        default:
            detail = String(describing: error)
        }
        return .failed(
            message: localized?.errorDescription ?? fallback,
            hint: localized?.recoverySuggestion,
            detail: detail
        )
    }
}

#if DEBUG
extension CalibrationViewModel {
    public func previewSeed(phase: Phase) {
        self.phase = phase
    }
}
#endif
