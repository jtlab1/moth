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

    /// How the capture was taken; persisted with the measurement via `flicker`.
    public var conditions: CaptureConditions? { flicker.conditions }

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
    public static let captureDuration: TimeInterval = CaptureStandard.captureDuration

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

    /// What a calibration must match to apply to the next capture; `nil` before `prepare()`.
    /// Lets the UI ask the store for the format-aware calibration state.
    public func activeFormatSignature() async -> CaptureFormatSignature? {
        await camera.activeFormatSignature()
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
            exposure: .metered,
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
    //
    // Driven in three steps so the UI can show each: readout pass 1, readout pass 2 (which must
    // agree with pass 1, `DeviceCalibration.agree`), then one response sweep:
    //
    //     let first = try await runner.calibrateReadout(referenceFrequencyHz: hz, duration: d)
    //     let second = try await runner.calibrateReadout(referenceFrequencyHz: hz, duration: d)
    //     guard DeviceCalibration.agree(first.lineReadoutTime, second.lineReadoutTime) else { … }
    //     let outcome = try await runner.measureResponseCurve(for: second) { sweepProgress in … }

    /// Readout passes the UI runs before the sweep.
    public static let readoutPassCount = 2

    /// One readout pass: a metered standard capture of the reference light, solved for line
    /// readout time. The result has no response curve; pass it to `measureResponseCurve(for:)`.
    /// Validates again after the calibrator on purpose: a wrong readout time is worth
    /// refusing twice.
    public func calibrateReadout(
        referenceFrequencyHz: Double,
        duration: TimeInterval = CaptureStandard.captureDuration,
        onProgress: (@Sendable (CaptureProgress) -> Void)? = nil
    ) async throws -> DeviceCalibration {
        let frames = try await camera.capture(
            duration: duration,
            lineReadoutTime: nil,
            calibration: nil,
            exposure: .metered,
            onProgress: onProgress
        )
        defer { frames.releaseFrames() }

        let solved = try await calibrator.solveLineReadoutTime(
            from: frames,
            knownFrequencyHz: referenceFrequencyHz
        )

        // What the capture actually ran as (recorded in its conditions), so a fresh calibration
        // applies to the next capture from the same format.
        let format = CaptureFormatSignature(metadata: frames.metadata)
        let plausible = DeviceCalibration.plausibleLineReadoutRange(for: format)
        guard plausible.contains(solved) else {
            throw AnalysisError.implausibleCalibration(solved: solved, plausible: plausible)
        }

        return DeviceCalibration(
            deviceModelIdentifier: DeviceIdentity.modelIdentifier,
            lineReadoutTime: solved,
            referenceFrequencyHz: referenceFrequencyHz,
            calibratedLineCount: frames.metadata.lineCount,
            format: format,
            calibrationVersion: DeviceCalibration.currentVersion
        )
    }

    /// The gain sweep: up to `CaptureStandard.responseSweepSteps` settled captures two stops
    /// either side of the metered gain (`CaptureStandard.responseSweepExposures`), solved
    /// into a response curve.
    ///
    /// Never fails the calibration over the curve: an unsolvable sweep (or a capture error
    /// during it) returns `readout` with `ResponseCurve.standardSRGB`, the encoding the
    /// camera is forced into, and the reason in `responseCurveFailure`. Depth then still
    /// works, flagged as using the assumed curve. Only cancellation throws.
    public func measureResponseCurve(
        for readout: DeviceCalibration,
        onProgress: (@Sendable (ResponseSweepProgress) -> Void)? = nil
    ) async throws -> CalibrationOutcome {
        do {
            let curve = try await runResponseSweep(format: readout.format, onProgress: onProgress)
            return CalibrationOutcome(calibration: readout.withResponseCurve(curve), responseCurveFailure: nil)
        } catch let error where Self.isCancellation(error) {
            throw error
        } catch {
            return CalibrationOutcome(
                calibration: readout.withResponseCurve(.standardSRGB),
                responseCurveFailure: Self.failureReason(error)
            )
        }
    }

    private func runResponseSweep(
        format: CaptureFormatSignature,
        onProgress: (@Sendable (ResponseSweepProgress) -> Void)?
    ) async throws -> ResponseCurve {
        guard let limits = await camera.standardExposureLimits() else {
            throw CaptureSetupError.notPrepared
        }
        // Metered once, before the first step: between steps preview AE is still settling
        // from the last one. Read-back ISOs, not these, are what the solver uses.
        let metered = await camera.meteredStandardISO() ?? (limits.iso.lowerBound * limits.iso.upperBound).squareRoot()
        let exposures = CaptureStandard.responseSweepExposures(
            meteredISO: metered, isoRange: limits.iso, exposureRange: limits.duration
        )
        var sweep: [FrameSequence] = []
        defer { sweep.forEach { $0.releaseFrames() } }

        for (index, planned) in exposures.enumerated() {
            try Task.checkCancellation()
            let step = index + 1
            let stepCount = exposures.count
            var stepProgress: (@Sendable (CaptureProgress) -> Void)?
            if let onProgress {
                stepProgress = { progress in
                    onProgress(ResponseSweepProgress(step: step, stepCount: stepCount, capture: progress))
                }
            }
            let frames = try await camera.capture(
                duration: CaptureStandard.responseSweepStepDuration,
                lineReadoutTime: nil,
                calibration: nil,
                exposure: .fixed(iso: planned.iso, duration: planned.duration),
                onProgress: stepProgress
            )
            sweep.append(frames)
            #if DEBUG
            Self.debugLogSweepStep(frames, step: step, requested: planned)
            #endif
            // A mid-sweep format change would mix two encodings in one curve.
            guard CaptureFormatSignature(metadata: frames.metadata).matches(format) else {
                throw AnalysisError.responseCurveUnsolvable(
                    reason: "the camera changed format during the sweep"
                )
            }
        }
        let curve = try await calibrator.solveResponseCurve(from: sweep)
        #if DEBUG
        Self.debugLogCurve(curve)
        #endif
        return curve
    }

    #if DEBUG
    /// Requested vs read-back ISO and the step's mean luma: brightness should rise with
    /// read-back ISO × exposure, roughly as gain^(1/2.2).
    private static func debugLogSweepStep(_ frames: FrameSequence, step: Int, requested: CaptureStandard.ResponseSweepExposure) {
        let isos = frames.metadata.frames.map(\.iso).sorted()
        let exposures = frames.metadata.frames.map(\.exposureDuration).sorted()
        var sum = 0.0
        var count = 0
        try? frames.forEachPlane { _, plane, _ in
            for y in 0..<plane.height {
                let row = plane.rowBytes(y)
                for x in 0..<plane.width { sum += Double(row[x]) }
            }
            count += plane.width * plane.height
        }
        print(String(
            format: "Moth sweep step %d: requested ISO %.0f at 1/%.0f s, read-back ISO %.0f, exposure 1/%.0f s, %d frames, mean luma %.1f, mode %@",
            step, requested.iso, 1 / requested.duration, isos.isEmpty ? 0 : isos[isos.count / 2],
            exposures.isEmpty ? 0 : 1 / exposures[exposures.count / 2],
            frames.count, count > 0 ? sum / Double(count) : 0,
            String(describing: frames.metadata.frames.first?.exposureMode)
        ))
    }
    #endif

    #if DEBUG
    /// The solved curve's local gamma (d ln light / d ln code) at a few codes: sRGB reads
    /// ≈1.7 at 32, ≈2.0 at 64, ≈2.2–2.3 from 128 up. Much steeper inflates depth.
    private static func debugLogCurve(_ curve: ResponseCurve) {
        let local = [32, 64, 128, 192, 240].map { code -> String in
            let low = Double(curve.values[code - 8]), high = Double(curve.values[code + 8])
            guard low > 0, high > 0 else { return "\(code): –" }
            return String(format: "%d: %.2f", code, log(high / low) / log(Double(code + 8) / Double(code - 8)))
        }
        print("Moth response curve local gamma — " + local.joined(separator: ", "))
    }
    #endif

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let analysis = error as? AnalysisError, analysis == .cancelled { return true }
        return false
    }

    private static func failureReason(_ error: Error) -> String {
        if case let AnalysisError.responseCurveUnsolvable(reason) = error { return reason }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Progress through the response sweep: step `step` of `stepCount` (1-based), and that
/// step's own capture progress.
public struct ResponseSweepProgress: Sendable, Equatable {
    public let step: Int
    public let stepCount: Int
    public let capture: CaptureProgress

    public init(step: Int, stepCount: Int, capture: CaptureProgress) {
        self.step = step
        self.stepCount = stepCount
        self.capture = capture
    }

    /// Across the whole sweep, 0...1.
    public var fraction: Double {
        guard stepCount > 0 else { return 0 }
        let completed = Double(min(max(step - 1, 0), stepCount))
        return min(1, (completed + capture.fraction) / Double(stepCount))
    }

    public var isDim: Bool { capture.isDim }
}

/// A finished calibration and, if the response curve couldn't be solved, why. The calibration
/// is valid either way; without a curve only frequency (Tier 2) is unlocked.
public struct CalibrationOutcome: Sendable, Equatable {
    public let calibration: DeviceCalibration
    public let responseCurveFailure: String?

    public init(calibration: DeviceCalibration, responseCurveFailure: String?) {
        self.calibration = calibration
        self.responseCurveFailure = responseCurveFailure
    }

    /// Depth (Tier 1) needs the response curve.
    public var unlocksDepth: Bool { calibration.responseCurve != nil }

    /// Depth works, but from the standard sRGB curve rather than one measured on this phone.
    public var usesAssumedResponse: Bool { calibration.responseCurve?.isStandardAssumption ?? false }
}

extension DeviceCalibration {
    /// Same calibration (identity, readout, format, version) with `curve` attached.
    public func withResponseCurve(_ curve: ResponseCurve?) -> DeviceCalibration {
        DeviceCalibration(
            id: id,
            deviceModelIdentifier: deviceModelIdentifier,
            lineReadoutTime: lineReadoutTime,
            referenceFrequencyHz: referenceFrequencyHz,
            calibratedLineCount: calibratedLineCount,
            format: format,
            responseCurve: curve,
            calibrationVersion: calibrationVersion,
            capturedAt: capturedAt
        )
    }
}
