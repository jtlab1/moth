#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit

/// Backing layer, not a sublayer, so it resizes itself; manual layout jumps during rotation.
public final class CameraPreviewUIView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    public var session: AVCaptureSession? {
        get { previewLayer.session }
        set { previewLayer.session = newValue }
    }
}

/// Never animates: a flicker-measurement viewfinder that flickers would hurt the people it's for.
public struct CameraPreview: UIViewRepresentable {
    private let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = session
        // Cropping costs nothing: analysis reads the buffers, never this layer.
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera preview"
        view.accessibilityHint = "Point the top of the phone at the light you want to measure."
        // One static element: a preview that announced changes would be noise.
        view.accessibilityTraits = .image
        return view
    }

    public func updateUIView(_ view: CameraPreviewUIView, context: Context) {
        if view.session !== session {
            view.session = session
        }
    }
}
#endif
