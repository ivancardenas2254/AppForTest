import UIKit

final class AppContainer {
    let configuration: AppConfiguration
    let imageLoader: PhotoImageLoading
    let cameraAuthorization: CameraAuthorization
    let apiTestRepository: MDTPRepository

    let loadPhotos: LoadPhotosUseCase
    let capturePhoto: CapturePhotoUseCase
    let deletePhoto: DeletePhotoUseCase
    let savePhotoToLibrary: SavePhotoToLibraryUseCase
    let syncPhotos: SyncPhotosUseCase

    init(configuration: AppConfiguration = .live) {
        self.configuration = configuration

        let photoRepository = LocalPhotoRepository()
        let photoLibraryRepository = SystemPhotoLibraryRepository()
        let remoteRepository = MDTPAPITestRepository(
            configuration: configuration,
            deviceName: UIDevice.current.name
        )
        let hasher = SHA256PhotoHasher()

        self.imageLoader = PhotoImageLoader()
        self.cameraAuthorization = AVCameraAuthorization()
        self.apiTestRepository = remoteRepository

        self.loadPhotos = LoadPhotosUseCase(repository: photoRepository)
        self.capturePhoto = CapturePhotoUseCase(repository: photoRepository)
        self.deletePhoto = DeletePhotoUseCase(repository: photoRepository)
        self.savePhotoToLibrary = SavePhotoToLibraryUseCase(repository: photoLibraryRepository)
        self.syncPhotos = SyncPhotosUseCase(
            photoRepository: photoRepository,
            remoteRepository: remoteRepository,
            hasher: hasher
        )
    }
}
