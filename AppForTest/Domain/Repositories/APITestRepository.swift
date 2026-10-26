import Foundation

protocol APITestRepository {
    var baseURL: URL { get }
    var storedDeviceID: String? { get }

    func health() async throws -> HealthStatus
    func registerDevice() async throws -> String
    func listDevices(pageSize: UInt32) async throws -> [DeviceSummary]
    func searchPhotos(pageSize: UInt32) async throws -> PhotoSearchResult
    func getRecord(recordID: String) async throws -> RemoteRecord
    func transferStatus(deviceID: String, transferID: String) async throws -> TransferStatusSummary
    func download(record: RemoteRecord) async throws -> DownloadSummary
}

protocol RemotePhotoRepository {
    func ensureDevice() async throws -> String
    func fetchPhotoHashes(deviceID: String) async throws -> Set<Data>
    func fetchPhotoRecords(deviceID: String) async throws -> [RemoteRecord]
    func upload(photo: Photo, deviceID: String) async throws -> UploadSummary
}

protocol MDTPRepository: APITestRepository, RemotePhotoRepository {}
