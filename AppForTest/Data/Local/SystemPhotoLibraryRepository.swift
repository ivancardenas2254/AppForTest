import Foundation
import Photos

final class SystemPhotoLibraryRepository: PhotoLibraryRepository {
    func saveToPhotoLibrary(_ photo: Photo) async throws {
        guard await requestAddOnlyAccess() else {
            throw PhotoLibraryError.permissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: photo.url)
            }
        } catch {
            throw PhotoLibraryError.saveFailed(error)
        }
    }

    private func requestAddOnlyAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }
}
