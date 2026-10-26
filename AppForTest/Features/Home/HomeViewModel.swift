import Combine
import UIKit

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published var isCameraPresented = false
    @Published var capturedPhoto: Photo?
    @Published var viewerPhoto: Photo?
    @Published var alertItem: AlertItem?

    private let loadPhotos: LoadPhotosUseCase
    private let capturePhoto: CapturePhotoUseCase
    private let deletePhoto: DeletePhotoUseCase
    private let cameraAuthorization: CameraAuthorization

    init(
        loadPhotos: LoadPhotosUseCase,
        capturePhoto: CapturePhotoUseCase,
        deletePhoto: DeletePhotoUseCase,
        cameraAuthorization: CameraAuthorization
    ) {
        self.loadPhotos = loadPhotos
        self.capturePhoto = capturePhoto
        self.deletePhoto = deletePhoto
        self.cameraAuthorization = cameraAuthorization
    }

    func onAppear() {
        refresh()
    }

    func refresh() {
        do {
            photos = try loadPhotos.execute()
        } catch {
            showError(title: "No se pudieron cargar las fotos", error: error)
        }
    }

    func openCamera() {
        guard cameraAuthorization.isCameraAvailable else {
            alertItem = AlertItem(
                title: "Cámara no disponible",
                message: "Este dispositivo (o el simulador) no tiene cámara. Usa un iPhone real.",
                showsSettingsButton: false
            )
            return
        }

        switch cameraAuthorization.status() {
        case .authorized:
            isCameraPresented = true
        case .notDetermined:
            Task {
                let granted = await cameraAuthorization.requestAccess()
                if granted {
                    isCameraPresented = true
                } else {
                    showCameraPermissionDeniedAlert()
                }
            }
        case .denied:
            showCameraPermissionDeniedAlert()
        }
    }

    func capture(_ image: UIImage) {
        isCameraPresented = false

        guard let data = image.jpegData(compressionQuality: 0.9) else {
            alertItem = AlertItem(
                title: "No se pudo guardar",
                message: "No se pudo convertir la imagen a JPEG.",
                showsSettingsButton: false
            )
            return
        }

        do {
            let photo = try capturePhoto.execute(data: data, fileExtension: "jpg")
            refresh()
            Task { @MainActor [weak self] in
                self?.capturedPhoto = photo
            }
        } catch {
            showError(title: "No se pudo guardar", error: error)
        }
    }

    func select(_ photo: Photo) {
        viewerPhoto = photo
    }

    func delete(_ photo: Photo) {
        do {
            try deletePhoto.execute(photo)
            refresh()
        } catch {
            showError(title: "No se pudo eliminar", error: error)
        }
    }

    private func showCameraPermissionDeniedAlert() {
        alertItem = AlertItem(
            title: "Permiso de cámara denegado",
            message: "Activa el acceso a la cámara en Ajustes para poder usarla.",
            showsSettingsButton: true
        )
    }

    private func showError(title: String, error: Error) {
        alertItem = AlertItem(
            title: title,
            message: error.localizedDescription,
            showsSettingsButton: false
        )
    }
}
