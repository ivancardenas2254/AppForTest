import SwiftUI
import UIKit

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let url: URL
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let showsSettingsButton: Bool
}

struct PhotoPreviewView: View {
    let photo: CapturedPhoto

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isSaving = false
    @State private var savedToLibrary = false
    @State private var alertItem: AlertItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)

                    Text(photo.url.path)
                        .font(.caption2)
                        .monospaced()
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .padding(.top, 8)
                } else {
                    ProgressView()
                        .tint(.white)
                }

                Spacer()

                bottomBar
            }
        }
        .task {
            image = UIImage(contentsOfFile: photo.url.path)
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

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            Spacer()

            Text(photo.url.lastPathComponent)
                .font(.caption)
                .monospaced()
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Color.clear
                .frame(width: 38, height: 38)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if savedToLibrary {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Guardada en Fotos")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
            } else {
                Button(action: saveToLibrary) {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isSaving ? "Guardando..." : "Guardar en Fotos")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSaving)
            }

            Button(action: { dismiss() }) {
                Text("Cerrar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.white)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func saveToLibrary() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await PhotoStore.saveToPhotoLibrary(at: photo.url)
                PhotoStore.removeTemporaryFile(at: photo.url)
                savedToLibrary = true
            } catch let error as PhotoStoreError {
                alertItem = AlertItem(
                    title: "No se pudo guardar",
                    message: error.errorDescription ?? "Error desconocido.",
                    showsSettingsButton: error.showsSettingsButton
                )
            } catch {
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
    PhotoPreviewView(photo: CapturedPhoto(url: FileManager.default.temporaryDirectory.appendingPathComponent("IMG-preview.jpg")))
}
