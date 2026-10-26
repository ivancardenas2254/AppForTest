import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @State private var showCamera = false
    @State private var capturedPhoto: CapturedPhoto?
    @State private var viewerPhoto: CapturedPhoto?
    @State private var alertItem: AlertItem?
    @State private var captures: [URL] = []
    @StateObject private var apiTests = APITestViewModel()
    @State private var showAPIMenu = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    VStack(spacing: 20) {
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        Button(action: openCamera) {
                            Label("Abrir cámara", systemImage: "camera.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                    }
                    .padding()

                    Divider()

                    gallery
                }
                .navigationTitle("AppForTest")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAPIMenu.toggle()
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("Pruebas de API")
                    }
                }

                if showAPIMenu {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { closeAPIMenu() }
                        .transition(.opacity)

                    APITestMenuView(model: apiTests) {
                        closeAPIMenu()
                    }
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showAPIMenu)
        }
        .onAppear {
            PhotoStore.purgeTemporaryLeftovers()
            refreshCaptures()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                capture(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $capturedPhoto, onDismiss: refreshCaptures) { photo in
            PhotoPreviewView(photo: photo)
        }
        .fullScreenCover(item: $viewerPhoto, onDismiss: refreshCaptures) { photo in
            PhotoViewerView(photo: photo)
        }
        .alert(item: $alertItem) { item in
            if item.showsSettingsButton {
                return Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    primaryButton: .default(Text("Abrir Ajustes"), action: openSettings),
                    secondaryButton: .cancel(Text("Cerrar"))
                )
            }
            return Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if captures.isEmpty {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("Aún no hay fotos")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Toma tu primera foto con el botón de arriba.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(captures, id: \.self) { url in
                        Button {
                            viewerPhoto = CapturedPhoto(url: url)
                        } label: {
                            PhotoThumbnailView(url: url)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    private func refreshCaptures() {
        captures = PhotoStore.listCaptures()
    }

    private func closeAPIMenu() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showAPIMenu = false
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            alertItem = AlertItem(
                title: "Cámara no disponible",
                message: "Este dispositivo (o el simulador) no tiene cámara. Usa un iPhone real.",
                showsSettingsButton: false
            )
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showCamera = true
                    } else {
                        showCameraPermissionDeniedAlert()
                    }
                }
            }
        default:
            showCameraPermissionDeniedAlert()
        }
    }

    private func showCameraPermissionDeniedAlert() {
        alertItem = AlertItem(
            title: "Permiso de cámara denegado",
            message: "Activa el acceso a la cámara en Ajustes para poder usarla.",
            showsSettingsButton: true
        )
    }

    private func capture(_ image: UIImage) {
        showCamera = false
        do {
            let temporaryURL = try PhotoStore.writeToTemporaryDirectory(image)
            let localURL = try PhotoStore.saveLocally(movingFrom: temporaryURL)
            let photo = CapturedPhoto(url: localURL)
            DispatchQueue.main.async {
                capturedPhoto = photo
            }
        } catch {
            DispatchQueue.main.async {
                alertItem = AlertItem(
                    title: "No se pudo guardar",
                    message: error.localizedDescription,
                    showsSettingsButton: false
                )
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    ContentView()
}
