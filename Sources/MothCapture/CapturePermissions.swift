import AVFoundation
import Foundation

/// "Not asked" and "refused" need different screens: after a refusal only Settings helps.
public enum PermissionState: String, Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    /// Parental controls or MDM; the user can't grant it.
    case restricted
}

extension PermissionState {
    public var isUsable: Bool { self == .granted }

}

public enum CapturePermissions {

    // MARK: - Camera

    public static var camera: PermissionState {
        translate(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Prompts only if not yet asked.
    @discardableResult
    public static func requestCamera() async -> PermissionState {
        guard camera == .notDetermined else { return camera }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return camera
    }

    // MARK: -

    private static func translate(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}

/// Kept next to the prompting code so the two can't drift apart.
public enum PermissionUsageStrings {
    public static let cameraValue =
        "Moth uses the camera to measure how the room's lighting flickers. No photos or video are saved."
}
