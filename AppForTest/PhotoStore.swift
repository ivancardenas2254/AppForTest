import Foundation
import UIKit
import Photos

enum PhotoStoreError: LocalizedError {
    case encodeFailed
    case permissionDenied
    case saveFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "No se pudo convertir la imagen a JPEG."
        case .permissionDenied:
            return "No se tiene permiso para guardar en Fotos. Activa el acceso en Ajustes."
        case .saveFailed(let underlying):
            return "No se pudo guardar en Fotos: \(underlying.localizedDescription)"
        }
    }

    var showsSettingsButton: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

enum PhotoStore {
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func writeToTemporaryDirectory(_ image: UIImage) throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw PhotoStoreError.encodeFailed
        }
        let fileName = "IMG-\(fileNameFormatter.string(from: Date())).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func saveToPhotoLibrary(at url: URL) async throws {
        guard await requestAddOnlyAccess() else {
            throw PhotoStoreError.permissionDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        } catch {
            throw PhotoStoreError.saveFailed(underlying: error)
        }
    }

    static func removeTemporaryFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func requestAddOnlyAccess() async -> Bool {
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
