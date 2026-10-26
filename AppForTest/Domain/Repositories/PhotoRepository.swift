import Foundation

protocol PhotoRepository {
    func fetchPhotos() throws -> [Photo]
    func savePhoto(data: Data, fileExtension: String) throws -> Photo
    func deletePhoto(_ photo: Photo) throws
}

protocol PhotoLibraryRepository {
    func saveToPhotoLibrary(_ photo: Photo) async throws
}

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "No se tiene permiso para guardar en Fotos. Activa el acceso en Ajustes."
        case .saveFailed(let error):
            return "No se pudo guardar en Fotos: \(error.localizedDescription)"
        }
    }

    var showsSettingsButton: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}
