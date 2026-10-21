import AVFoundation
import MothCapture
import SwiftUI

/// Placeholder without UIKit, so the screen still type-checks away from iOS.
struct MeasureCameraPreview: View {
    let session: AVCaptureSession

    var body: some View {
        #if canImport(UIKit)
        CameraPreview(session: session)
        #else
        RoundedRectangle(cornerRadius: MothTheme.controlCornerRadius, style: .continuous)
            .fill(Color.black)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Camera preview is only available on iOS")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        #endif
    }
}
