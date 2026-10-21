import AVFoundation
import CoreMedia
import Foundation

// iOS-only AVFoundation members isolated so the rest of the capture layer type-checks with
// `swift build`. Non-iOS branches are placeholders never used at runtime.

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

    /// Requires the device configuration lock. A no-op off-iOS.
    func setCustomExposure(duration: CMTime, iso: Float) {
        #if os(iOS)
        setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        #endif
    }

    static func disableWideColor(on session: AVCaptureSession) {
        #if os(iOS)
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        #endif
    }
}
