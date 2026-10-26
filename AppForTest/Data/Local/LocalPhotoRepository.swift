import Foundation

final class LocalPhotoRepository: PhotoRepository {
    private let fileManager: FileManager
    private let directory: URL
    private let fileNameFormatter: DateFormatter

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        self.fileNameFormatter = formatter
    }

    var capturesDirectory: URL { directory }

    func fetchPhotos() throws -> [Photo] {
        purgeTemporaryLeftovers()

        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let items = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return items
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return Photo(url: url, createdAt: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func savePhoto(data: Data, fileExtension: String) throws -> Photo {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = "IMG-\(fileNameFormatter.string(from: Date()))"
        var destination = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName)-\(counter).\(fileExtension)")
            counter += 1
        }

        try data.write(to: destination, options: .atomic)
        return Photo(url: destination, createdAt: Date())
    }

    func deletePhoto(_ photo: Photo) throws {
        try fileManager.removeItem(at: photo.url)
    }

    private func purgeTemporaryLeftovers() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in items
        where url.pathExtension.lowercased() == "jpg" && url.lastPathComponent.hasPrefix("IMG-") {
            try? fileManager.removeItem(at: url)
        }
    }
}
