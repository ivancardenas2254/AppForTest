import Foundation

struct SyncPhotosUseCase {
    private let photoRepository: PhotoRepository
    private let remoteRepository: RemotePhotoRepository
    private let hasher: PhotoHashing

    init(
        photoRepository: PhotoRepository,
        remoteRepository: RemotePhotoRepository,
        hasher: PhotoHashing
    ) {
        self.photoRepository = photoRepository
        self.remoteRepository = remoteRepository
        self.hasher = hasher
    }

    func execute() async throws -> SyncReport {
        let photos = try photoRepository.fetchPhotos()
        guard !photos.isEmpty else { return .noPhotos }

        let deviceID = try await remoteRepository.ensureDevice()
        var knownHashes = try await remoteRepository.fetchPhotoHashes(deviceID: deviceID)
        var uploadedCount = 0
        var skippedCount = 0
        var failures: [String] = []

        for photo in photos.reversed() {
            do {
                let hash = try hasher.hash(fileAt: photo.url)
                if knownHashes.contains(hash) {
                    skippedCount += 1
                    continue
                }

                _ = try await remoteRepository.upload(photo: photo, deviceID: deviceID)
                knownHashes.insert(hash)
                uploadedCount += 1
            } catch {
                failures.append("\(photo.fileName): \(error.localizedDescription)")
            }
        }

        let records = try await remoteRepository.fetchPhotoRecords(deviceID: deviceID)
        return SyncReport(
            deviceID: deviceID,
            uploadedCount: uploadedCount,
            skippedCount: skippedCount,
            failedCount: failures.count,
            remoteRecordCount: records.count,
            records: records,
            failures: failures
        )
    }
}
