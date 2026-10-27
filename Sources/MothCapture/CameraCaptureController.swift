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

    /// Driven by elapsed time instead of frame count, since bursty delivery would make the ring stutter.
    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

/// `@unchecked Sendable` because all session, device and capture state is touched only on `sessionQueue`.
/// Every capture follows `CaptureStandard`: fixed format and exposure, settle, record, then hand back to AE.
public final class CameraCaptureController: NSObject, @unchecked Sendable {

    /// Hitting this stops the capture early; a short capture that analysis rejects beats a memory crash.
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
    /// Catches a cancel that arrives before setup reaches `sessionQueue`, so `continuation` isn't left hanging.
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

        // Wide color adds an unknown transfer curve, and the session would otherwise change the color space on us.
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
        // Dropped frames look like signal once frames are an array, so cap memory with a byte budget instead.
        // Any drops that still happen get counted.
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

    /// Needs the device config lock. Runs again at capture start in case a session restart reset the format or rate.
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

    /// Asks for full-range 4:2:0 explicitly; otherwise the output might pick video range or BGRA.
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

    /// Cancels any running capture first, or it would hang and later return stale frames as a measurement.
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

    /// The standard format's ISO and exposure ranges for the response sweep. `nil` before `prepare()`.
    public func standardExposureLimits() async -> (iso: ClosedRange<Float>, duration: ClosedRange<TimeInterval>)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(iso: ClosedRange<Float>, duration: ClosedRange<TimeInterval>)?, Never>) in
            sessionQueue.async {
                guard self.isConfigured, self.device != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let capability = self.capabilityLocked(calibration: nil)
                continuation.resume(returning: (capability.isoRange, capability.exposureDurationRange))
            }
        }
    }

    /// The ISO the scene wants right now at the standard exposure, left unclamped
    /// so the sweep can tell when the scene is too bright for the min ISO and shorten exposure instead.
    public func meteredStandardISO() async -> Float? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Float?, Never>) in
            sessionQueue.async {
                guard self.isConfigured, let device = self.device else {
                    continuation.resume(returning: nil)
                    return
                }
                let capability = self.capabilityLocked(calibration: nil)
                let exposure = CaptureStandard.exposureDuration(clampedTo: capability.exposureDurationRange)
                let autoISO = Double(device.currentISO)
                let autoDuration = device.currentExposureSeconds
                guard autoISO > 0, autoDuration > 0, exposure > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let iso = autoISO * autoDuration / exposure * pow(2, CaptureStandard.meteringBiasEV)
                continuation.resume(returning: iso.isFinite ? Float(iso) : nil)
            }
        }
    }

    /// What a calibration has to match to apply to this format: buffer size, frame rate, pixel format and standard exposure.
    /// Uses the fixed standard exposure, not the read-back one, which wanders under AE.
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

    /// Gates Tier 1, so it leans toward `false`, since wrongly claiming linearity gives a confident wrong depth.
    /// It can't check the sensor's own response curve.
    static func believesCaptureIsLinear(device: AVCaptureDevice) -> Bool {
        guard device.isExposureModeSupported(.custom) else { return false }
        if device.isVideoHDRActive { return false }
        let format = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        return format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    // MARK: - Capture

    /// Needs a running session. Cancelling or `stopPreview()` ends it with `.cancelled`.
    /// `duration` only counts settled frames, and `onProgress` runs on the capture queue.
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
                    // Only use a calibration that matches this format, readout time and curve both,
                    // or a stale one would steer the frequency search under a Tier 3 label.
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
                        // Nothing to wait for; the read-back values will show the capture isn't at the standard exposure.
                        self.settleGate.exposureApplied(syncTime: -.infinity)
                    }

                    // Check before any frames arrive so a hopeless scene warns right away.
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

    /// A calibration contributes both its readout time and curve if it matches the format, otherwise neither.
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
        case let .fixed(iso, duration):
            return ExposurePlan.fixed(
                iso: iso,
                duration: duration,
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

    /// Resumes the caller exactly once and always hands exposure back to AE so the preview sees the scene again.
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

    /// Same "crushed" cutoff as `RowBrightnessExtractor`, measured above black so video range still warns.
    private static let dimLuminanceMargin: Float = 3

    /// Time-based so the indicator behaves the same at any frame rate.
    private static let liveDimTimeConstant: TimeInterval = 0.3

    static func blackPoint(for pixelFormat: UInt32) -> Float {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
    }

    /// Uses a sparse grid instead of full row means since this runs every frame and can't cause drops.
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

    /// Picked per `CaptureStandard` via `CaptureFormatSelector`, never by frame rate.
    /// Returns `nil` instead of a fallback, since a different format would make readings incomparable.
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

        // Read back, not requested; after settling these match what the sensor actually used.
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
        // Drops while settling don't matter, but in the valid window they leave a gap in time.
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
