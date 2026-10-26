import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MeasurementCore

public struct CaptureProgress: Sendable, Equatable {
    public let framesCaptured: Int
    public let elapsed: TimeInterval
    public let duration: TimeInterval

    /// Cheap per-frame estimate, so a bad aim shows up while there's still time to fix it.
    public let isDim: Bool

    public init(framesCaptured: Int, elapsed: TimeInterval, duration: TimeInterval, isDim: Bool = false) {
        self.framesCaptured = framesCaptured
        self.elapsed = elapsed
        self.duration = duration
        self.isDim = isDim
    }

    /// Driven by elapsed time, not frame count: delivery is bursty and a stuttering ring is
    /// motion this app promised not to produce.
    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

/// `@unchecked Sendable`: every session, device, and capture-state mutation happens on
/// `sessionQueue`, which is also the sample-buffer delegate queue.
///
/// Every capture runs under `CaptureStandard`: one format (29 fps, ~1920×1080, 8-bit 4:2:0),
/// the standard exposure with ISO alone adapting, and forced imaging state (focus, white
/// balance, HDR, colour space, tone mapping, stabilization…). Preview meters continuously;
/// a capture switches to custom exposure, discards frames until it has settled, records
/// `settledFrames`-gated frames and the conditions they were taken under, then hands
/// exposure back to continuous AE.
public final class CameraCaptureController: NSObject, @unchecked Sendable {

    /// Reached, the capture stops early: a short sequence analysis can reject beats a
    /// memory termination the user reads as a crash.
    public static let byteBudget = 250 * 1024 * 1024

    private let sessionQueue = DispatchQueue(label: "com.moth.capture.session")
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    private var device: AVCaptureDevice?
    private var isConfigured = false

    // Fixed at configuration; touched only on `sessionQueue`.
    private var standardFormat: AVCaptureDevice.Format?
    private var pinnedFrameRate: Double = CaptureStandard.frameRate
    private var outputPixelFormat: UInt32 = CaptureStandard.preferredPixelFormat

    /// The clock exposure completion handlers report in.
    private var deviceClock: CMClock?

    // Touched only on `sessionQueue`.
    private var builder: FrameSequenceBuilder?
    private var copier: FrameCopier?
    private var continuation: CheckedContinuation<FrameSequence, Error>?
    private var captureDuration: TimeInterval = 0
    private var retainedBytes = 0
    private var lineReadoutTimeForCapture: TimeInterval?
    private var responseCurveForCapture: ResponseCurve?
    private var capabilityForCapture: DeviceCapabilityProfile?
    private var progressHandler: (@Sendable (CaptureProgress) -> Void)?
    private var captureStartedAt = Date()
    private var settleGate = SettleGate()
    private var conditionsAccumulator = CaptureConditionsAccumulator()
    private var thermalStateAtStart: Int?
    private var deliveredPixelFormat: UInt32?

    /// True while a capture holds custom exposure; `finishCapture` hands it back to AE.
    private var exposureOverridden = false

    /// Metering already says the scene is too dim at maximum ISO: warn from the first frame.
    private var meteringPredictsDim = false

    /// Same raw 8-bit code `RowBrightnessExtractor` classifies rows in.
    private var liveLuminanceEMA: Float?
    private var lastLiveSampleTime: TimeInterval?
    private var liveBlackPoint: Float = 0
    private var activeCaptureID: UUID?
    /// A cancellation that lands before setup reaches `sessionQueue` would otherwise be
    /// lost, leaving `continuation` waiting on frames nobody delivers.
    private var captureCancelledBeforeStart: UUID?

    /// Read-only use: configuring it from outside would race `sessionQueue`.
    public var previewSession: AVCaptureSession { session }

    // MARK: - Configuration

    /// Idempotent, so a view can call it on every appearance.
    public func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureIfNeeded() throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !isConfigured else { return }
        guard CapturePermissions.camera == .granted else {
            throw CaptureSetupError.cameraPermissionMissing
        }
        guard let device = Self.discoverCamera() else {
            throw CaptureSetupError.noCameraAvailable
        }

        session.beginConfiguration()
        // Any named preset would override the chosen format, and with it the frame rate.
        session.sessionPreset = AVCaptureSession.measurementPreset

        // Wide colour inserts an unknown transfer curve into the signal, and the session would
        // otherwise re-pick the colour space behind `applyStandardImagingState`.
        AVCaptureDevice.disableWideColor(on: session)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CaptureSetupError.inputUnavailable(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureSetupError.inputUnavailable("session refused the camera input")
        }
        session.addInput(input)
        deviceClock = input.ports.first { $0.mediaType == .video }?.clock

        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        // A dropped frame is indistinguishable from signal once frames are an array; the byte
        // budget bounds memory instead. Drops that still happen are counted.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CaptureSetupError.outputUnavailable
        }
        session.addOutput(videoOutput)

        do {
            try configureDevice(device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        configureOutput()
        session.commitConfiguration()

        self.device = device
        self.isConfigured = true
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let format = Self.selectFormat(for: device) else {
            throw CaptureSetupError.noSuitableFormat
        }
        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureSetupError.deviceLockFailed(error.localizedDescription)
        }
        defer { device.unlockForConfiguration() }

        standardFormat = format
        applyStandardFormatLocked(device)
        device.applyStandardImagingState()
        // Colour space and HDR changes can reset the frame durations; pin again.
        applyStandardFormatLocked(device)
        // Preview meters continuously; a capture converts that metering to the standard.
        device.restoreContinuousAutoExposure()
    }

    /// Requires the device configuration lock. Re-run at capture start in case a session
    /// restart reset the format or frame rate.
    private func applyStandardFormatLocked(_ device: AVCaptureDevice) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let standardFormat else { return }
        if device.activeFormat != standardFormat {
            device.activeFormat = standardFormat
        }
        // Pin both ends: setting only the minimum lets the device slow down in dim light.
        let frameDuration = Self.standardFrameDuration
        if device.activeVideoMinFrameDuration != frameDuration {
            device.activeVideoMinFrameDuration = frameDuration
        }
        if device.activeVideoMaxFrameDuration != frameDuration {
            device.activeVideoMaxFrameDuration = frameDuration
        }
        let readBack = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        pinnedFrameRate = readBack > 0 && abs(1 / readBack - CaptureStandard.frameRate) / CaptureStandard.frameRate < 1e-3
            ? CaptureStandard.frameRate
            : (readBack > 0 ? 1 / readBack : CaptureStandard.frameRate)
    }

    /// Exactly 1/29 s.
    static let standardFrameDuration = CMTime(value: 1000, timescale: CMTimeScale((CaptureStandard.frameRate * 1000).rounded()))

    /// Requests full-range 4:2:0 explicitly: left to itself the output may pick video range
    /// (or BGRA) and the response curve would describe a different encoding.
    private func configureOutput() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let available = videoOutput.availableVideoPixelFormatTypes.map { UInt32($0) }
        let native = standardFormat.map { CMFormatDescriptionGetMediaSubType($0.formatDescription) }
        let requested: UInt32?
        if available.contains(CaptureStandard.preferredPixelFormat) {
            requested = CaptureStandard.preferredPixelFormat
        } else if let native, CaptureStandard.acceptedPixelFormats.contains(native), available.contains(native) {
            requested = native
        } else {
            requested = available.first { CaptureStandard.acceptedPixelFormats.contains($0) }
        }
        if let requested {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: requested]
            outputPixelFormat = requested
        } else {
            outputPixelFormat = native ?? CaptureStandard.preferredPixelFormat
        }
        videoOutput.connection(with: .video)?.applyStandardBufferState()
    }

    // MARK: - Preview

    public func startPreview() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    /// Cancels any in-flight capture first: otherwise it would hang, then swallow the next
    /// preview's first frame and return stale frames as a measurement.
    public func stopPreview() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.finishCapture(with: .failure(AnalysisError.cancelled))
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Capability

    private func capabilityLocked(calibration: DeviceCalibration?) -> DeviceCapabilityProfile {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let model = DeviceIdentity.modelIdentifier
        let isCalibrated = activeFormatSignatureLocked().map { signature in
            calibration?.appliesTo(modelIdentifier: model, format: signature) ?? false
        } ?? false

        guard let device else {
            return DeviceCapabilityProfile(
                modelIdentifier: model,
                supportsManualExposure: false,
                exposureDurationRange: 1e-5...1,
                isoRange: 1...100,
                maximumFrameRate: CaptureStandard.frameRate,
                providesLinearCapture: false,
                isCalibrated: isCalibrated
            )
        }

        let format = standardFormat ?? device.activeFormat
        let minDuration = format.minExposureSeconds
        let maxDuration = format.maxExposureSeconds

        return DeviceCapabilityProfile(
            modelIdentifier: model,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            exposureDurationRange: minDuration...max(minDuration, maxDuration),
            isoRange: format.minISOValue...max(format.minISOValue, format.maxISOValue),
            // The pinned rate: the standard never runs faster.
            maximumFrameRate: pinnedFrameRate,
            providesLinearCapture: Self.believesCaptureIsLinear(device: device),
            isCalibrated: isCalibrated
        )
    }

    /// `nil` before `prepare()`. Calibration records this so `capabilityLocked` can match it.
    public func activeFormatSignature() async -> CaptureFormatSignature? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CaptureFormatSignature?, Never>) in
            sessionQueue.async {
                continuation.resume(returning: self.activeFormatSignatureLocked())
            }
        }
    }

    /// The standard format's ISO range, which the response sweep spans. `nil` before `prepare()`.
    public func standardISORange() async -> ClosedRange<Float>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClosedRange<Float>?, Never>) in
            sessionQueue.async {
                guard self.isConfigured, let format = self.standardFormat ?? self.device?.activeFormat else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: format.minISOValue...max(format.minISOValue, format.maxISOValue))
            }
        }
    }

    /// The ISO a `.metered` capture would use right now: preview AE's reading converted to
    /// the standard exposure. The response sweep centres on it so every step sees the scene.
    public func meteredStandardISO() async -> Float? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Float?, Never>) in
            sessionQueue.async {
                guard self.isConfigured, let device = self.device else {
                    continuation.resume(returning: nil)
                    return
                }
                let capability = self.capabilityLocked(calibration: nil)
                let plan = Self.exposurePlan(for: .metered, device: device, capability: capability)
                continuation.resume(returning: plan.iso)
            }
        }
    }

    /// What a calibration must match to apply to captures from the configured format: the
    /// standard format's buffer size, the pinned rate, the pixel format the output delivers,
    /// and the standard exposure (clamped to the format). Deterministic, never the read-back
    /// exposure, which wanders under preview AE.
    private func activeFormatSignatureLocked(pixelFormat: UInt32? = nil) -> CaptureFormatSignature? {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isConfigured || device != nil, let format = standardFormat ?? device?.activeFormat else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let minExposure = format.minExposureSeconds
        return CaptureFormatSignature(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameRate: pinnedFrameRate,
            pixelFormat: pixelFormat ?? deliveredPixelFormat ?? outputPixelFormat,
            exposureDuration: CaptureStandard.exposureDuration(
                clampedTo: minExposure...max(minExposure, format.maxExposureSeconds)
            )
        )
    }

    /// Gates Tier 1, so it errs towards `false`: wrongly claiming linearity yields a confident,
    /// wrong depth. It can't check the sensor's own response curve.
    static func believesCaptureIsLinear(device: AVCaptureDevice) -> Bool {
        guard device.isExposureModeSupported(.custom) else { return false }
        if device.isVideoHDRActive { return false }
        let format = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    // MARK: - Capture

    /// Requires a running session. Cancelling the task or `stopPreview()` ends it with
    /// `.cancelled`. `duration` is settled time: frames before the custom exposure lands, and
    /// `CaptureStandard.settleFrames` after, are discarded and don't count.
    /// `onProgress` is called on the capture queue.
    public func capture(
        duration: TimeInterval,
        lineReadoutTime: TimeInterval?,
        calibration: DeviceCalibration?,
        exposure: CaptureExposure = .metered,
        retention: FrameRetentionPolicy = .default,
        onProgress: (@Sendable (CaptureProgress) -> Void)? = nil
    ) async throws -> FrameSequence {
        let captureID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FrameSequence, Error>) in
                sessionQueue.async {
                    if self.captureCancelledBeforeStart == captureID {
                        self.captureCancelledBeforeStart = nil
                        continuation.resume(throwing: AnalysisError.cancelled)
                        return
                    }
                    guard self.isConfigured, let device = self.device else {
                        continuation.resume(throwing: CaptureSetupError.notPrepared)
                        return
                    }
                    // Otherwise it would wait forever for frames that never come.
                    guard self.session.isRunning else {
                        continuation.resume(throwing: CaptureSetupError.sessionNotRunning)
                        return
                    }
                    guard self.continuation == nil else {
                        continuation.resume(throwing: CaptureSetupError.captureAlreadyRunning)
                        return
                    }
                    do {
                        try device.lockForConfiguration()
                    } catch {
                        continuation.resume(throwing: CaptureSetupError.deviceLockFailed(error.localizedDescription))
                        return
                    }

                    self.applyStandardFormatLocked(device)
                    device.applyStandardImagingState()
                    // Colour space and HDR changes can reset the frame durations; pin again.
                    self.applyStandardFormatLocked(device)

                    let capability = self.capabilityLocked(calibration: calibration)
                    let plan = Self.exposurePlan(for: exposure, device: device, capability: capability)
                    let maxFrames = Int((capability.maximumFrameRate * duration).rounded(.up)) + 30

                    self.builder = FrameSequenceBuilder(maximumFrameCount: maxFrames)
                    self.copier = FrameCopier(policy: retention)
                    self.continuation = continuation
                    self.activeCaptureID = captureID
                    self.captureDuration = duration
                    self.retainedBytes = 0
                    // Only a calibration that applies to this format may shape the signal: its
                    // readout time as much as its curve, or an outdated or foreign calibration
                    // would steer the frequency search under a Tier 3 label.
                    let inputs = Self.calibrationInputs(
                        lineReadoutTime: lineReadoutTime, calibration: calibration, applies: capability.isCalibrated
                    )
                    self.lineReadoutTimeForCapture = inputs.lineReadoutTime
                    self.responseCurveForCapture = inputs.responseCurve
                    self.capabilityForCapture = capability
                    self.progressHandler = onProgress
                    self.captureStartedAt = Date()
                    self.settleGate = SettleGate()
                    self.conditionsAccumulator = CaptureConditionsAccumulator(expectedFrameCount: maxFrames)
                    self.thermalStateAtStart = ProcessInfo.processInfo.thermalState.rawValue
                    self.deliveredPixelFormat = nil
                    self.meteringPredictsDim = plan.predictsDim
                    self.liveLuminanceEMA = nil
                    self.lastLiveSampleTime = nil
                    self.liveBlackPoint = Self.blackPoint(for: self.outputPixelFormat)

                    let applied = device.setCustomExposure(
                        duration: plan.exposureDuration,
                        iso: plan.iso
                    ) { [weak self] syncTime in
                        guard let self else { return }
                        self.sessionQueue.async {
                            self.exposureApplied(syncTime: syncTime, captureID: captureID)
                        }
                    }
                    device.unlockForConfiguration()
                    self.exposureOverridden = applied
                    if !applied {
                        // Nothing to wait for; read-back values (and the analyser) will show
                        // the capture isn't at the standard exposure.
                        self.settleGate.exposureApplied(syncTime: -.infinity)
                    }

                    // Before any frame arrives, so a hopeless scene warns immediately.
                    onProgress?(CaptureProgress(
                        framesCaptured: 0, elapsed: 0, duration: duration, isDim: plan.predictsDim
                    ))
                }
            }
        } onCancel: {
            self.sessionQueue.async {
                self.cancelCapture(captureID)
            }
        }
    }

    /// What a calibration contributes to a capture: both its readout time and curve when it
    /// applies to the capture's format, neither otherwise.
    static func calibrationInputs(
        lineReadoutTime: TimeInterval?,
        calibration: DeviceCalibration?,
        applies: Bool
    ) -> (lineReadoutTime: TimeInterval?, responseCurve: ResponseCurve?) {
        guard applies else { return (nil, nil) }
        return (lineReadoutTime, calibration?.responseCurve)
    }

    private static func exposurePlan(
        for exposure: CaptureExposure,
        device: AVCaptureDevice,
        capability: DeviceCapabilityProfile
    ) -> ExposurePlan {
        switch exposure {
        case .metered:
            // Read back from continuous AE, which has been metering the scene during preview.
            return ExposurePlan.metered(
                autoExposureDuration: device.currentExposureSeconds,
                autoExposureISO: device.currentISO,
                exposureRange: capability.exposureDurationRange,
                isoRange: capability.isoRange
            )
        case .fixedISO(let iso):
            return ExposurePlan.fixed(
                iso: iso,
                exposureRange: capability.exposureDurationRange,
                isoRange: capability.isoRange
            )
        }
    }

    private func exposureApplied(syncTime: CMTime, captureID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard activeCaptureID == captureID, syncTime.isNumeric else { return }
        let bufferTime = session.bufferTime(fromDeviceTime: syncTime, deviceClock: deviceClock)
        let seconds = CMTimeGetSeconds(bufferTime)
        guard seconds.isFinite else { return }
        settleGate.exposureApplied(syncTime: seconds)
    }

    private func cancelCapture(_ captureID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if activeCaptureID == captureID {
            finishCapture(with: .failure(AnalysisError.cancelled))
        } else {
            captureCancelledBeforeStart = captureID
        }
    }

    /// Resumes the waiting caller exactly once, and always hands exposure back to AE so the
    /// preview (and the next capture's metering) sees the scene again.
    private func finishCapture(with result: Result<FrameSequence, Error>) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let continuation else { return }
        self.continuation = nil
        activeCaptureID = nil
        builder?.discard()
        builder = nil
        copier?.reset()
        copier = nil
        progressHandler = nil
        capabilityForCapture = nil
        liveLuminanceEMA = nil
        lastLiveSampleTime = nil
        meteringPredictsDim = false
        restorePreviewExposure()
        continuation.resume(with: result)
    }

    private func restorePreviewExposure() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard exposureOverridden, let device else { return }
        exposureOverridden = false
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.restoreContinuousAutoExposure()
        device.unlockForConfiguration()
    }

    // MARK: - Live dimness sampling

    /// Same boundary `RowBrightnessExtractor` calls "crushed", measured above the pixel
    /// format's black so video range (black at 16) can still warn.
    private static let dimLuminanceMargin: Float = 3

    /// Time-based so the indicator behaves the same at any frame rate.
    private static let liveDimTimeConstant: TimeInterval = 0.3

    static func blackPoint(for pixelFormat: UInt32) -> Float {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
    }

    /// A sparse grid rather than full row means: this runs on every frame, settling ones
    /// included, and must never be what makes the queue drop frames.
    private func updateLiveDimState(sampling pixelBuffer: CVPixelBuffer, at presentationTime: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        let threshold = liveBlackPoint + Self.dimLuminanceMargin
        guard let sample = Self.sparseLumaSample(pixelBuffer) else {
            return (liveLuminanceEMA ?? 255) < threshold
        }

        if let previousEMA = liveLuminanceEMA, let lastTime = lastLiveSampleTime {
            let dt = max(0, presentationTime - lastTime)
            let alpha = Float(1 - exp(-dt / Self.liveDimTimeConstant))
            liveLuminanceEMA = previousEMA + alpha * (sample - previousEMA)
        } else {
            liveLuminanceEMA = sample
        }
        lastLiveSampleTime = presentationTime

        return liveLuminanceEMA! < threshold
    }

    /// Internal so tests can pin the grid math.
    static func sparseLumaSample(_ pixelBuffer: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else { return nil }

        let sampleRows = min(12, height)
        let sampleColumns = min(16, width)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0
        var count = 0
        for row in 0..<sampleRows {
            let y = height * row / sampleRows
            let rowStart = luma + y * bytesPerRow
            for column in 0..<sampleColumns {
                let x = width * column / sampleColumns
                sum += Int(rowStart[x])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Float(sum) / Float(count)
    }

    // MARK: - Device and format selection

    private static func discoverCamera() -> AVCaptureDevice? {
        // One lens, one calibration: other lenses have different line readout times.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    /// Per `CaptureStandard` via `CaptureFormatSelector`; never by frame rate. `nil` rather
    /// than an off-standard fallback: a silently different format would make every reading
    /// incomparable.
    static func selectFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = device.formats
        guard let index = CaptureFormatSelector.bestIndex(of: formats.map(\.captureDescriptor)) else {
            return nil
        }
        return formats[index]
    }
}

// MARK: - Frame delivery

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard continuation != nil, let builder, let copier, let device else { return }
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if deliveredPixelFormat == nil {
            let format = CVPixelBufferGetPixelFormatType(sourceBuffer)
            deliveredPixelFormat = format
            liveBlackPoint = Self.blackPoint(for: format)
        }

        let isDim = updateLiveDimState(sampling: sourceBuffer, at: presentationTime) || meteringPredictsDim

        guard settleGate.admit(presentationTime: presentationTime) else {
            progressHandler?(CaptureProgress(
                framesCaptured: 0, elapsed: 0, duration: captureDuration, isDim: isDim
            ))
            return
        }
        let elapsed = settleGate.elapsed(at: presentationTime)

        // Read back, not requested. After settling these match what the sensor used.
        let exposureDuration = device.currentExposureSeconds
        let iso = device.currentISO
        let mode: ExposureMode
        switch device.exposureMode {
        case .custom: mode = .manual
        case .locked: mode = .locked
        default: mode = .automatic
        }

        guard let retained = copier.retain(sourceBuffer) else {
            finishCapture(with: .failure(AnalysisError.insufficientSignal(
                reason: "could not allocate a frame buffer; device may be under memory pressure"
            )))
            return
        }

        let result = builder.append(
            pixelBuffer: retained,
            presentationTime: presentationTime,
            exposureDuration: exposureDuration,
            iso: iso,
            exposureMode: mode,
            lensAperture: device.currentLensAperture
        )
        conditionsAccumulator.recordFrame(
            presentationTime: presentationTime,
            exposureDuration: exposureDuration,
            iso: iso
        )

        retainedBytes += CVPixelBufferGetDataSize(retained)

        progressHandler?(CaptureProgress(
            framesCaptured: builder.count,
            elapsed: elapsed,
            duration: captureDuration,
            isDim: isDim
        ))

        let hitTime = elapsed >= captureDuration
        let hitCount = result == .full
        let hitBytes = retainedBytes >= Self.byteBudget
        guard hitTime || hitCount || hitBytes else { return }

        finalizeCapture()
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        // Drops while settling cost nothing; inside the valid window they're a hole in time.
        guard continuation != nil, settleGate.isSettled else { return }
        conditionsAccumulator.recordDrop()
    }

    private func finalizeCapture() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let builder, let copier, let capability = capabilityForCapture else { return }
        guard let dimensions = copier.retainedDimensions else {
            finishCapture(with: .failure(AnalysisError.tooFewFrames(captured: 0, required: 1)))
            return
        }

        // What the buffers actually are, not what was asked for.
        let pixelFormat = deliveredPixelFormat ?? outputPixelFormat
        let conditions = activeFormatSignatureLocked(pixelFormat: pixelFormat).map { signature in
            conditionsAccumulator.conditions(
                formatSignature: signature,
                settledFrameCount: settleGate.discardedFrameCount,
                thermalStateRawValue: thermalStateAtStart,
                lensPosition: device?.currentLensPosition,
                whiteBalanceLocked: device?.isWhiteBalanceLocked ?? false
            )
        }

        let sequence = builder.finalize(
            dimensions: dimensions,
            pixelFormat: pixelFormat,
            nominalFrameRate: pinnedFrameRate,
            region: copier.region,
            lineReadoutTime: lineReadoutTimeForCapture,
            responseCurve: responseCurveForCapture,
            deviceCapability: capability,
            startedAt: captureStartedAt,
            conditions: conditions
        )
        finishCapture(with: .success(sequence))
    }
}

/// Kept out of `AnalysisError`: nothing here is about signal.
public enum CaptureSetupError: Error, Sendable, Equatable, LocalizedError {
    case cameraPermissionMissing
    case noCameraAvailable
    case noSuitableFormat
    case inputUnavailable(String)
    case outputUnavailable
    case deviceLockFailed(String)
    case notPrepared
    case sessionNotRunning
    case captureAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .cameraPermissionMissing:
            return "Moth needs camera access to measure light."
        case .noCameraAvailable:
            return "No usable camera was found on this device."
        case .noSuitableFormat:
            return "This camera doesn't offer a video format Moth can measure with."
        case .inputUnavailable:
            return "The camera couldn't be opened. Another app may be using it."
        case .outputUnavailable:
            return "The camera couldn't be set up for measurement."
        case .deviceLockFailed:
            return "The camera was busy. Try again in a moment."
        case .notPrepared:
            return "The camera isn't ready yet."
        case .sessionNotRunning:
            return "The camera stopped before the measurement could start."
        case .captureAlreadyRunning:
            return "A measurement is already running."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cameraPermissionMissing:
            return "Turn on Camera for Moth in Settings."
        case .inputUnavailable, .deviceLockFailed, .captureAlreadyRunning:
            return "Close other apps using the camera, then try again."
        case .sessionNotRunning:
            return "Try again."
        case .noCameraAvailable, .noSuitableFormat, .outputUnavailable, .notPrepared:
            return nil
        }
    }
}
