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
        case capturing(CaptureProgress)
        case solving
        case confirming(CaptureProgress)
        case succeeded(DeviceCalibration)
        case rejected(solved: TimeInterval, plausible: ClosedRange<TimeInterval>)
                /// Two plausible solves disagreed, unlike `.rejected`, where one was implausible.
        case inconsistent(first: TimeInterval, second: TimeInterval)
        case failed(String)
    }

    public private(set) var phase: Phase
    public var mainsRegion: MainsRegion?

    private let runner: MeasurementRunner
    private let captureDuration: TimeInterval
    private var pendingFirstSolve: TimeInterval?

    /// Started in `init` so camera setup, which doesn't depend on the mains region, finishes
    /// while the user reads the picker instead of freezing after the tap.
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
            phase = .failed(Self.message(for: error, fallback: "Couldn't start the camera."))
            prepareTask = nil
            return
        }
        await runner.startPreview()
        phase = .previewing
    }

    /// Two captures must agree before either is trusted: one lucky-looking solve isn't enough.
    public func capture() {
        guard phase == .previewing, let mainsRegion else { return }
        pendingFirstSolve = nil
        Task { await runCalibrationPass(referenceFrequencyHz: mainsRegion.referenceFlickerFrequencyHz) }
    }

    private func runCalibrationPass(referenceFrequencyHz: Double) async {
        let isConfirmingPass = pendingFirstSolve != nil
        phase = isConfirmingPass
            ? .confirming(CaptureProgress(framesCaptured: 0, elapsed: 0, duration: captureDuration))
            : .capturing(CaptureProgress(framesCaptured: 0, elapsed: 0, duration: captureDuration))
        do {
            let calibration = try await runner.calibrate(
                referenceFrequencyHz: referenceFrequencyHz,
                duration: captureDuration,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if progress.fraction >= 1 {
                            self.phase = .solving
                        } else {
                            self.phase = isConfirmingPass ? .confirming(progress) : .capturing(progress)
                        }
                    }
                }
            )
            if let firstSolve = pendingFirstSolve {
                pendingFirstSolve = nil
                guard DeviceCalibration.agree(firstSolve, calibration.lineReadoutTime) else {
                    phase = .inconsistent(first: firstSolve, second: calibration.lineReadoutTime)
                    return
                }
                phase = .succeeded(calibration)
            } else {
                pendingFirstSolve = calibration.lineReadoutTime
                await runCalibrationPass(referenceFrequencyHz: referenceFrequencyHz)
            }
        } catch let AnalysisError.implausibleCalibration(solved, plausible) {
            pendingFirstSolve = nil
            phase = .rejected(solved: solved, plausible: plausible)
        } catch {
            pendingFirstSolve = nil
            phase = .failed(Self.message(for: error, fallback: "Calibration failed."))
        }
    }

    /// Restarts the preview, because `MeasureViewModel.reset()` stops the shared session.
    public func retry() {
        Task {
            pendingFirstSolve = nil
            await runner.startPreview()
            phase = .previewing
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

#if DEBUG
extension CalibrationViewModel {
    public func previewSeed(phase: Phase) {
        self.phase = phase
    }

    /// Debug-only. Still requires `mainsRegion`, so the fake can't disagree with the setting.
    public func skipForTesting() {
        guard let mainsRegion else { return }
        phase = .succeeded(DeviceCalibration(
            deviceModelIdentifier: DeviceIdentity.modelIdentifier,
            lineReadoutTime: 18.5e-6,
            referenceFrequencyHz: mainsRegion.referenceFlickerFrequencyHz,
            calibratedLineCount: 1080
        ))
    }
}
#endif
