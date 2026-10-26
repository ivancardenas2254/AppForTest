import Foundation

struct LoadPhotosUseCase {
    private let repository: PhotoRepository

    init(repository: PhotoRepository) {
        self.repository = repository
    }

    func execute() throws -> [Photo] {
        try repository.fetchPhotos()
    }
}

struct CapturePhotoUseCase {
    private let repository: PhotoRepository

    init(repository: PhotoRepository) {
        self.repository = repository
    }

    func execute(data: Data, fileExtension: String = "jpg") throws -> Photo {
        try repository.savePhoto(data: data, fileExtension: fileExtension)
    }
}

struct DeletePhotoUseCase {
    private let repository: PhotoRepository

    init(repository: PhotoRepository) {
        self.repository = repository
    }

    func execute(_ photo: Photo) throws {
        try repository.deletePhoto(photo)
    }
}

struct SavePhotoToLibraryUseCase {
    private let repository: PhotoLibraryRepository

    init(repository: PhotoLibraryRepository) {
        self.repository = repository
    }

    func execute(_ photo: Photo) async throws {
        try await repository.saveToPhotoLibrary(photo)
    }
}
