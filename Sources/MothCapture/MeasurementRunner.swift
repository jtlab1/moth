import AVFoundation
import Foundation
import MeasurementCore

/// Becomes a `RoomMeasurement` only once a room is picked, so a discarded reading never
/// touches storage.
public struct MeasurementDraft: Sendable {
    public let flicker: FlickerResult
    public let capturedAt: Date
    public let deviceModelIdentifier: String
    public let appVersion: String
    public let lineReadoutTimeUsed: TimeInterval?
    public let calibrationID: UUID?

    /// Display-only and never persisted.
    public let waveform: FlickerWaveform?

    public init(
        flicker: FlickerResult,
        capturedAt: Date = Date(),
        deviceModelIdentifier: String,
        appVersion: String,
        lineReadoutTimeUsed: TimeInterval? = nil,
        calibrationID: UUID? = nil,
        waveform: FlickerWaveform? = nil
    ) {
        self.flicker = flicker
        self.capturedAt = capturedAt
        self.deviceModelIdentifier = deviceModelIdentifier
        self.appVersion = appVersion
        self.lineReadoutTimeUsed = lineReadoutTimeUsed
        self.calibrationID = calibrationID
        self.waveform = waveform
    }

    /// Both are parameters because the rating doesn't exist yet when the draft is made, and
    /// this layer doesn't know `UserSettings`.
    public func measurement(roomID: UUID, comfortRating: Int? = nil, mainsRegion: MainsRegion? = nil) -> RoomMeasurement {
        RoomMeasurement(
            roomID: roomID,
            capturedAt: capturedAt,
            flicker: flicker,
            deviceModelIdentifier: deviceModelIdentifier,
            appVersion: appVersion,
            lineReadoutTimeUsed: lineReadoutTimeUsed,
            calibrationID: calibrationID,
            mainsRegion: mainsRegion,
            comfortRating: comfortRating
        )
    }
}

/// An actor so two measurements can never be in flight at once.
public actor MeasurementRunner {
    /// Fixed: under ~2 s there are too few cycles; over ~10 s nobody holds still.
    public static let captureDuration: TimeInterval = 4.0

    private let camera: CameraCaptureController
    private let flickerAnalyzer: any FlickerAnalyzing
    private let calibrator: any DeviceCalibrating

    public init(
        camera: CameraCaptureController = CameraCaptureController(),
        flickerAnalyzer: any FlickerAnalyzing,
        calibrator: any DeviceCalibrating
    ) {
        self.camera = camera
        self.flickerAnalyzer = flickerAnalyzer
        self.calibrator = calibrator
    }

    public nonisolated var previewSession: AVCaptureSession { camera.previewSession }

    public func prepare() async throws {
        try await camera.prepare()
    }

    public func startPreview() async {
        await camera.startPreview()
    }

    public func stopPreview() async {
        await camera.stopPreview()
    }

    // MARK: - Measurement

    public func measure(
        calibration: DeviceCalibration?,
        onProgress: (@Sendable (CaptureProgress) -> Void)? = nil
    ) async throws -> MeasurementDraft {
        let capturedAt = Date()
        let lineReadoutTime = calibration?.lineReadoutTime

        let frames = try await camera.capture(
            duration: Self.captureDuration,
            lineReadoutTime: lineReadoutTime,
            calibration: calibration,
            onProgress: onProgress
        )
        // `defer` so the throwing and cancelled paths release too.
        defer { frames.releaseFrames() }
        #if DEBUG
        if let dumpName = Self.debugPendingDumpName {
            Self.debugPendingDumpName = nil
            do {
                let url = try DebugFrameDump.write(frames, name: dumpName)
                print("Moth: dumped capture fixture \"\(dumpName)\" to \(url.path)")
            } catch {
                print("Moth: failed to dump capture fixture \"\(dumpName)\": \(error)")
            }
        }
        #endif
        let flicker = try await flickerAnalyzer.analyze(frames: frames, metadata: frames.metadata)

        // Best-effort: a waveform failure must never take down a measurement that succeeded.
        let waveform = flicker.frequencyHz.flatMap { frequencyHz -> FlickerWaveform? in
            guard let capture = try? RowBrightnessExtractor.extract(from: frames) else { return nil }
            return FlickerWaveformBuilder.fold(capture: capture, frequencyHz: frequencyHz)
        }

        return MeasurementDraft(
            flicker: flicker,
            capturedAt: capturedAt,
            deviceModelIdentifier: DeviceIdentity.modelIdentifier,
            appVersion: DeviceIdentity.appVersion,
            lineReadoutTimeUsed: flicker.tier == .tier3 ? nil : lineReadoutTime,
            calibrationID: flicker.tier == .tier3 ? nil : calibration?.id,
            waveform: waveform
        )
    }

    #if DEBUG
    /// Debug-only, one-shot. `nonisolated(unsafe)` because it's set from the main actor
    /// right before one `measure` call, and the camera refuses concurrent captures.
    public nonisolated(unsafe) static var debugPendingDumpName: String?
    #endif

    // MARK: - Calibration

    /// Validates again after the calibrator on purpose: a wrong readout time is worth
    /// refusing twice.
    public func calibrate(
        referenceFrequencyHz: Double,
        duration: TimeInterval,
        onProgress: (@Sendable (CaptureProgress) -> Void)? = nil
    ) async throws -> DeviceCalibration {
        let frames = try await camera.capture(
            duration: duration,
            lineReadoutTime: nil,
            calibration: nil,
            onProgress: onProgress
        )
        defer { frames.releaseFrames() }

        let solved = try await calibrator.solveLineReadoutTime(
            from: frames,
            knownFrequencyHz: referenceFrequencyHz
        )

        guard DeviceCalibration.isPlausible(solved) else {
            throw AnalysisError.implausibleCalibration(
                solved: solved,
                plausible: DeviceCalibration.plausibleLineReadoutRange
            )
        }

        return DeviceCalibration(
            deviceModelIdentifier: DeviceIdentity.modelIdentifier,
            lineReadoutTime: solved,
            referenceFrequencyHz: referenceFrequencyHz,
            calibratedLineCount: frames.metadata.lineCount
        )
    }
}
