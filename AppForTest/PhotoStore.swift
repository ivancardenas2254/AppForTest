import Foundation
import UIKit
import Photos
import ImageIO

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

    static func saveLocally(movingFrom temporaryURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        let baseName = temporaryURL.deletingPathExtension().lastPathComponent
        var destination = capturesDirectory.appendingPathComponent(temporaryURL.lastPathComponent)
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = capturesDirectory.appendingPathComponent("\(baseName)-\(counter).jpg")
            counter += 1
        }

        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static var capturesDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
    }

    static func listCaptures() -> [URL] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: capturesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    static func deleteCapture(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func purgeTemporaryLeftovers() {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in items
        where url.pathExtension.lowercased() == "jpg" && url.lastPathComponent.hasPrefix("IMG-") {
            try? fileManager.removeItem(at: url)
        }
    }

    static func thumbnail(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
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
