import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.updatePreviewOrientation()
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        updatePreviewOrientation()
    }

    func updatePreviewOrientation() {
        guard let connection = previewLayer.connection else { return }
        let angle = TeleprompterCameraOrientation.rotationAngle(
            interfaceOrientation: window?.windowScene?.interfaceOrientation,
            deviceOrientation: UIDevice.current.orientation
        )
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

enum TeleprompterCameraOrientation {
    static func rotationAngle(
        interfaceOrientation: UIInterfaceOrientation?,
        deviceOrientation: UIDeviceOrientation
    ) -> CGFloat {
        let orientation: UIInterfaceOrientation
        if let interfaceOrientation, interfaceOrientation != .unknown {
            orientation = interfaceOrientation
        } else {
            // The embedded Wow app uses a pre-scene UIKit window. Physical
            // landscape directions are opposite to interface directions.
            orientation = switch deviceOrientation {
            case .landscapeLeft: .landscapeRight
            case .landscapeRight: .landscapeLeft
            case .portraitUpsideDown: .portraitUpsideDown
            default: .portrait
            }
        }
        return switch orientation {
        case .landscapeLeft:
            0
        case .landscapeRight:
            180
        case .portraitUpsideDown:
            270
        case .portrait, .unknown:
            90
        @unknown default:
            90
        }
    }
}
