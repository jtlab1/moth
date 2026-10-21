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
public final class CameraCaptureController: NSObject, @unchecked Sendable {

    /// Reached, the capture stops early: a short sequence analysis can reject beats a
    /// memory termination the user reads as a crash.
    public static let byteBudget = 250 * 1024 * 1024

    private let sessionQueue = DispatchQueue(label: "com.moth.capture.session")
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    private var device: AVCaptureDevice?
    private var isConfigured = false

    // Touched only on `sessionQueue`.
    private var builder: FrameSequenceBuilder?
    private var copier: FrameCopier?
    private var continuation: CheckedContinuation<FrameSequence, Error>?
    private var captureStart: TimeInterval = 0
    private var captureDuration: TimeInterval = 0
    private var retainedBytes = 0
    private var lineReadoutTimeForCapture: TimeInterval?
    private var capabilityForCapture: DeviceCapabilityProfile?
    private var progressHandler: (@Sendable (CaptureProgress) -> Void)?
    private var captureStartedAt = Date()

    /// Same raw 8-bit code `RowBrightnessExtractor` classifies rows in.
    private var liveLuminanceEMA: Float?
    private var lastLiveSampleTime: TimeInterval?
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

        // Wide colour inserts an unknown transfer curve into the signal.
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

        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        // A dropped frame is indistinguishable from signal once frames are an array; the byte
        // budget bounds memory instead.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CaptureSetupError.outputUnavailable
        }
        session.addOutput(videoOutput)

        session.commitConfiguration()

        try configureDevice(device)
        self.device = device
        self.isConfigured = true
    }

    private func configureDevice(_ device: AVCaptureDevice) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureSetupError.deviceLockFailed(error.localizedDescription)
        }
        defer { device.unlockForConfiguration() }

        guard let format = Self.selectFormat(for: device) else {
            throw CaptureSetupError.noSuitableFormat
        }
        device.activeFormat = format

        // Pin both ends: setting only the minimum lets the device slow down in dim light.
        let maxRate = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 30
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(maxRate.rounded()))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Video HDR is a non-linear, scene-dependent transform of the measured quantity.
        device.disableVideoHDRIfSupported()

        // Locked for stability: a refocus or white-balance shift would read as modulation.
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }

        // `configureExposure` runs with the configuration lock held.
        configureExposure(for: device, frameDuration: frameDuration)
    }

    // Custom exposure lands asynchronously, so early frames carry the old values; that's
    // why metadata records read-back values per frame.
    private func configureExposure(for device: AVCaptureDevice, frameDuration: CMTime) {
        guard device.isExposureModeSupported(.custom) else { return }

        // Static, not converge-then-lock: nothing is aimed at yet. Biased short and low-ISO
        // because saturation and dim signal both fail safely with their own guidance.
        let format = device.activeFormat
        let minDuration = format.minExposureSeconds
        let maxDuration = format.maxExposureSeconds

        // `maxDuration` is the format's absolute ceiling, not the pinned rate's frame period.
        // Exposing longer than a frame silently throttles delivery, so bound by `frameDuration`.
        let frameDurationSeconds = CMTimeGetSeconds(frameDuration)
        let frameBound = frameDurationSeconds * 0.8
        let target = minDuration + (maxDuration - minDuration) * 0.1
        let exposureDuration = CMTime(
            seconds: min(max(min(target, frameBound), minDuration), maxDuration),
            preferredTimescale: 1_000_000
        )

        let minISO = format.minISOValue
        let maxISO = format.maxISOValue
        let targetISO = minISO + (maxISO - minISO) * 0.15
        let iso = min(max(targetISO, minISO), maxISO)

        device.setCustomExposure(duration: exposureDuration, iso: iso)
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
        let isCalibrated = calibration?.appliesTo(modelIdentifier: model) ?? false

        guard let device, let format = device.activeFormat as AVCaptureDevice.Format? else {
            return DeviceCapabilityProfile(
                modelIdentifier: model,
                supportsManualExposure: false,
                exposureDurationRange: 1e-5...1,
                isoRange: 1...100,
                maximumFrameRate: 30,
                providesLinearCapture: false,
                isCalibrated: isCalibrated
            )
        }

        let minDuration = format.minExposureSeconds
        let maxDuration = format.maxExposureSeconds

        return DeviceCapabilityProfile(
            modelIdentifier: model,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            exposureDurationRange: minDuration...max(minDuration, maxDuration),
            isoRange: format.minISOValue...max(format.minISOValue, format.maxISOValue),
            maximumFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30,
            providesLinearCapture: Self.believesCaptureIsLinear(device: device),
            isCalibrated: isCalibrated
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
    /// `.cancelled`.
    /// `onProgress` is called on the capture queue.
    public func capture(
        duration: TimeInterval,
        lineReadoutTime: TimeInterval?,
        calibration: DeviceCalibration?,
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
                    guard self.isConfigured else {
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

                    let capability = self.capabilityLocked(calibration: calibration)
                    let maxFrames = Int((capability.maximumFrameRate * duration).rounded(.up)) + 30

                    self.builder = FrameSequenceBuilder(maximumFrameCount: maxFrames)
                    self.copier = FrameCopier(policy: retention)
                    self.continuation = continuation
                    self.activeCaptureID = captureID
                    self.captureStart = 0
                    self.captureDuration = duration
                    self.retainedBytes = 0
                    self.lineReadoutTimeForCapture = lineReadoutTime
                    self.capabilityForCapture = capability
                    self.progressHandler = onProgress
                    self.captureStartedAt = Date()
                    self.liveLuminanceEMA = nil
                    self.lastLiveSampleTime = nil
                }
            }
        } onCancel: {
            self.sessionQueue.async {
                self.cancelCapture(captureID)
            }
        }
    }

    private func cancelCapture(_ captureID: UUID) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if activeCaptureID == captureID {
            finishCapture(with: .failure(AnalysisError.cancelled))
        } else {
            captureCancelledBeforeStart = captureID
        }
    }

    /// Resumes the waiting caller exactly once.
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
        continuation.resume(with: result)
    }

    // MARK: - Live dimness sampling

    /// Same boundary `RowBrightnessExtractor` calls "crushed", so the live warning predicts the
    /// failure the capture would hit anyway.
    private static let dimLuminanceThreshold: Float = 3

    /// Time-based so the indicator behaves the same at 30 and 240 fps.
    private static let liveDimTimeConstant: TimeInterval = 0.3

    /// A sparse grid rather than full row means: this runs on every frame, up to 240 fps, and
    /// must never be what makes the queue drop frames.
    private func updateLiveDimState(sampling pixelBuffer: CVPixelBuffer, at presentationTime: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let sample = Self.sparseLumaSample(pixelBuffer) else {
            return (liveLuminanceEMA ?? 255) < Self.dimLuminanceThreshold
        }

        if let previousEMA = liveLuminanceEMA, let lastTime = lastLiveSampleTime {
            let dt = max(0, presentationTime - lastTime)
            let alpha = Float(1 - exp(-dt / Self.liveDimTimeConstant))
            liveLuminanceEMA = previousEMA + alpha * (sample - previousEMA)
        } else {
            liveLuminanceEMA = sample
        }
        lastLiveSampleTime = presentationTime

        return liveLuminanceEMA! < Self.dimLuminanceThreshold
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

    /// Priorities: full-range 4:2:0 (≈15% more amplitude resolution than video range),
    /// frame rate, then height (rows are the time axis); width only adds noise averaging.
    static func selectFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = -Double.infinity

        for format in device.formats {
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let isFullRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let isVideoRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            guard isFullRange || isVideoRange else { continue }

            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxRate > 0 else { continue }

            var score = 0.0
            score += maxRate * 10                      // frame rate dominates
            score += Double(dimensions.height) * 0.5   // rows are the time axis
            score += isFullRange ? 200 : 0
            if dimensions.width > 1920 {
                score -= Double(dimensions.width - 1920) * 0.2
            }
            if device.isExposureModeSupported(.custom) {
                // A long minimum exposure integrates across cycles and flattens the modulation.
                let minExposure = format.minExposureSeconds
                if minExposure > 0 { score += min(200, 1 / minExposure * 0.02) }
            }

            if score > bestScore {
                bestScore = score
                best = format
            }
        }
        return best ?? device.formats.last
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
        if captureStart == 0 { captureStart = presentationTime }
        let elapsed = presentationTime - captureStart

        // Read back, not requested. Under continuous auto these may lag a frame or two, which
        // is why `hasStableExposure` exists.
        let exposureDuration = device.currentExposureSeconds
        let iso = device.currentISO
        let mode: ExposureMode
        switch device.exposureMode {
        case .custom: mode = .manual
        case .locked: mode = .locked
        default: mode = .automatic
        }

        let isDim = updateLiveDimState(sampling: sourceBuffer, at: presentationTime)

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
        guard continuation != nil else { return }
    }

    private func finalizeCapture() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let builder, let copier, let capability = capabilityForCapture else { return }
        guard let dimensions = copier.retainedDimensions else {
            finishCapture(with: .failure(AnalysisError.tooFewFrames(captured: 0, required: 1)))
            return
        }

        let pixelFormat = videoOutput.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? UInt32
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let sequence = builder.finalize(
            dimensions: dimensions,
            pixelFormat: pixelFormat,
            nominalFrameRate: capability.maximumFrameRate,
            region: copier.region,
            lineReadoutTime: lineReadoutTimeForCapture,
            deviceCapability: capability,
            startedAt: captureStartedAt
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
