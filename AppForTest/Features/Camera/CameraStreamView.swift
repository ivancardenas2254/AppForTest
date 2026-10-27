import AVFoundation
import SwiftUI
import UIKit

struct CameraStreamScreen: View {
    let session: AVCaptureSession
    let statusText: String
    let isStreaming: Bool
    let onStop: () -> Void

    var body: some View {
        ZStack {
            CameraStreamPreviewView(session: session)
                .ignoresSafeArea()

            VStack {
                header
                Spacer()
                footer
            }
            .padding(24)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isStreaming ? Color.red : Color.secondary)
                .frame(width: 10, height: 10)
            Text(isStreaming ? "Stream de cámara" : "Stream detenido")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text(statusText)
                .font(.caption.monospaced())
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))

            Button(action: onStop) {
                Label("Detener stream", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundColor(.white)
            }
            .disabled(!isStreaming)
            .opacity(isStreaming ? 1 : 0.6)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct CameraStreamPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        configure(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        configure(uiView.previewLayer)
    }

    private func configure(_ layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection,
              connection.isVideoOrientationSupported else {
            return
        }
        connection.videoOrientation = .portrait
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
