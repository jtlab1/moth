import AVFoundation
import CoreMedia
import Foundation
import MeasurementCore

// Keeps iOS-only AVFoundation calls here so the rest builds with `swift build`. Non-iOS branches never run.

extension AVCaptureSession {
    /// Named presets override the chosen format, and with it the frame rate.
    static var measurementPreset: AVCaptureSession.Preset {
        #if os(iOS)
        return .inputPriority
        #else
        return .high
        #endif
    }
}

extension AVCaptureDevice.Format {
    /// Plain values for `CaptureFormatSelector`.
    var captureDescriptor: CaptureFormatDescriptor {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        #if os(iOS)
        let binned = isVideoBinned
        #else
        let binned = false
        #endif
        return CaptureFormatDescriptor(
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            pixelFormat: CMFormatDescriptionGetMediaSubType(formatDescription),
            frameRateRanges: videoSupportedFrameRateRanges.map { $0.minFrameRate...max($0.minFrameRate, $0.maxFrameRate) },
            minimumExposure: minExposureSeconds,
            isBinned: binned
        )
    }

    var minExposureSeconds: TimeInterval {
        #if os(iOS)
        return CMTimeGetSeconds(minExposureDuration)
        #else
        return 1.0 / 8000.0
        #endif
    }

    var maxExposureSeconds: TimeInterval {
        #if os(iOS)
        return CMTimeGetSeconds(maxExposureDuration)
        #else
        return 1.0 / 3.0
        #endif
    }

    var minISOValue: Float {
        #if os(iOS)
        return minISO
        #else
        return 34
        #endif
    }

    var maxISOValue: Float {
        #if os(iOS)
        return maxISO
        #else
        return 3072
        #endif
    }

}

extension AVCaptureDevice {
    /// Under continuous auto this can lag a frame or two; AVFoundation has no per-buffer value.
    var currentExposureSeconds: TimeInterval {
        #if os(iOS)
        return CMTimeGetSeconds(exposureDuration)
        #else
        return 1.0 / 2000.0
        #endif
    }

    var currentISO: Float {
        #if os(iOS)
        return iso
        #else
        return 400
        #endif
    }

    var currentLensAperture: Float? {
        #if os(iOS)
        return lensAperture
        #else
        return nil
        #endif
    }

    /// Requires the device configuration lock.
    func disableVideoHDRIfSupported() {
        #if os(iOS)
        guard activeFormat.isVideoHDRSupported else { return }
        automaticallyAdjustsVideoHDREnabled = false
        isVideoHDREnabled = false
        #endif
    }

    /// Always false off-iOS.
    var isVideoHDRActive: Bool {
        #if os(iOS)
        return activeFormat.isVideoHDRSupported && isVideoHDREnabled
        #else
        return false
        #endif
    }

    /// Needs the config lock. Returns `false` if custom exposure isn't available.
    /// `applied` gets the sync time of the first buffer with the new values, on any queue.
    @discardableResult
    func setCustomExposure(
        duration: TimeInterval,
        iso: Float,
        applied: (@Sendable (CMTime) -> Void)? = nil
    ) -> Bool {
        #if os(iOS)
        guard isExposureModeSupported(.custom) else { return false }
        let format = activeFormat
        let clampedDuration = min(max(duration, format.minExposureSeconds), format.maxExposureSeconds)
        let clampedISO = min(max(iso, format.minISO), format.maxISO)
        setExposureModeCustom(
            duration: CMTime(seconds: clampedDuration, preferredTimescale: 1_000_000_000),
            iso: clampedISO,
            completionHandler: applied.map { handler in { syncTime in handler(syncTime) } }
        )
        return true
        #else
        return false
        #endif
    }

    /// Needs the config lock. Preview meters continuously so capture start reflects where the camera's aimed.
    func restoreContinuousAutoExposure() {
        #if os(iOS)
        if isExposureModeSupported(.continuousAutoExposure) {
            exposureMode = .continuousAutoExposure
        }
        #endif
    }

    /// Needs the config lock. Turns off everything that would warp or shift the measured rows.
    /// Safe to call again, so capture start re-applies it in case a session restart reset something.
    func applyStandardImagingState() {
        #if os(iOS)
        // Video HDR: a non-linear, scene-dependent transform.
        disableVideoHDRIfSupported()

        // sRGB, never P3/HLG: wide colour inserts an unknown transfer curve.
        if activeFormat.supportedColorSpaces.contains(.sRGB) {
            activeColorSpace = .sRGB
        }

        // Global tone mapping would bend the curve differently with scene content.
        if activeFormat.isGlobalToneMappingSupported {
            isGlobalToneMappingEnabled = false
        }

        // Low-light boost lengthens frames and changes gain behind our back.
        if isLowLightBoostSupported {
            automaticallyEnablesLowLightBoostWhenAvailable = false
        }

        // Distortion correction resamples rows, mixing readout times.
        if isGeometricDistortionCorrectionSupported {
            isGeometricDistortionCorrectionEnabled = false
        }

        // Auto frame rate would undo the pinned 29 fps in dim light.
        if activeFormat.isAutoVideoFrameRateSupported {
            isAutoVideoFrameRateEnabled = false
        }

        // Zoom crops and resamples the sensor rows.
        if videoZoomFactor != 1.0 {
            videoZoomFactor = 1.0
        }

        // The torch would itself be a (PWM-driven) light source in the measurement.
        if hasTorch, torchMode != .off, isTorchModeSupported(.off) {
            torchMode = .off
        }

        isSubjectAreaChangeMonitoringEnabled = false

        // Deliberate, consistent defocus: blurs scene detail; per-row means don't need it.
        if isLockingFocusWithCustomLensPositionSupported {
            setFocusModeLocked(lensPosition: CaptureStandard.focusLensPosition, completionHandler: nil)
        } else if isFocusModeSupported(.locked) {
            focusMode = .locked
        }

        // Fixed 5000 K / tint 0 gains: a white-balance shift would read as modulation.
        if isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: CaptureStandard.whiteBalanceTemperature,
                tint: CaptureStandard.whiteBalanceTint
            )
            var gains = deviceWhiteBalanceGains(for: values)
            let ceiling = max(1, maxWhiteBalanceGain)
            gains.redGain = min(max(gains.redGain, 1), ceiling)
            gains.greenGain = min(max(gains.greenGain, 1), ceiling)
            gains.blueGain = min(max(gains.blueGain, 1), ceiling)
            setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if isWhiteBalanceModeSupported(.locked) {
            whiteBalanceMode = .locked
        }

        // AE's target must be unbiased, or the metering conversion inherits the bias.
        if isExposureModeSupported(.continuousAutoExposure), exposureTargetBias != 0 {
            setExposureTargetBias(0, completionHandler: nil)
        }
        #else
        if isFocusModeSupported(.locked) { focusMode = .locked }
        if isWhiteBalanceModeSupported(.locked) { whiteBalanceMode = .locked }
        #endif
    }

    /// Read back, for `CaptureConditions`; `nil` off-iOS.
    var currentLensPosition: Float? {
        #if os(iOS)
        return lensPosition
        #else
        return nil
        #endif
    }

    var isWhiteBalanceLocked: Bool {
        whiteBalanceMode == .locked
    }

    static func disableWideColor(on session: AVCaptureSession) {
        #if os(iOS)
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        #endif
    }
}

extension AVCaptureConnection {
    /// Rows have to stay the sensor's raw readout rows, so no stabilization, rotation or mirroring.
    func applyStandardBufferState() {
        #if os(iOS)
        if isVideoStabilizationSupported {
            preferredVideoStabilizationMode = .off
        }
        if isVideoRotationAngleSupported(0), videoRotationAngle != 0 {
            videoRotationAngle = 0
        }
        #endif
        if isVideoMirroringSupported {
            automaticallyAdjustsVideoMirroring = false
            isVideoMirrored = false
        }
    }
}

extension AVCaptureSession {
    /// Converts a device-clock sync time to the sample buffer clock. Identity if either clock is unknown.
    func bufferTime(fromDeviceTime time: CMTime, deviceClock: CMClock?) -> CMTime {
        #if os(iOS)
        guard let deviceClock, let bufferClock = synchronizationClock else { return time }
        return CMSyncConvertTime(time, from: deviceClock, to: bufferClock)
        #else
        return time
        #endif
    }
}
