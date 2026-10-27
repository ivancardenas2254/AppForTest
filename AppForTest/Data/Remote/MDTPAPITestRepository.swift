import Foundation
import MDTPClient

struct APITestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class MDTPAPITestRepository: MDTPRepository {
    let baseURL: URL

    private let client: MDTPClient
    private let deviceName: String
    private let userDefaults: UserDefaults

    private enum Keys {
        static let deviceID = "mdtp.deviceID"
        static let clientInstanceID = "mdtp.clientInstanceID"
    }

    init(
        configuration: AppConfiguration,
        deviceName: String,
        userDefaults: UserDefaults = .standard
    ) {
        self.baseURL = configuration.apiBaseURL
        self.client = MDTPClient(configuration: MDTPConfiguration(baseURL: configuration.apiBaseURL))
        self.deviceName = deviceName
        self.userDefaults = userDefaults
    }

    var storedDeviceID: String? {
        loadDeviceID()
    }

    func health() async throws -> HealthStatus {
        try await mapError {
            let response = try await client.health()
            return HealthStatus(status: response.status)
        }
    }

    func registerDevice() async throws -> String {
        try await mapError {
            let response = try await client.registerDevice(
                clientInstanceID: clientInstanceID(),
                deviceName: deviceName
            )
            persist(deviceID: response.deviceID)
            return hex(response.deviceID)
        }
    }

    func ensureDevice() async throws -> String {
        try await registerDevice()
    }

    func listDevices(pageSize: UInt32) async throws -> [DeviceSummary] {
        try await mapError {
            let response = try await client.listDevices(pageSize: pageSize)
            return response.devices.map { device in
                DeviceSummary(
                    id: hex(device.deviceID),
                    name: device.deviceName,
                    platform: device.platform,
                    recordCount: Int(device.recordCount)
                )
            }
        }
    }

    func searchPhotos(pageSize: UInt32) async throws -> PhotoSearchResult {
        try await mapError {
            var request = SearchRecordsRequest()
            request.dataCategory = MDTPDataCategory.photo
            request.pageSize = pageSize
            request.sortBy = "created_at"
            request.descending = true

            let response = try await client.searchRecords(request)
            return PhotoSearchResult(
                records: response.records.map(mapRecord),
                totalCount: Int(response.totalCount)
            )
        }
    }

    func getRecord(recordID: String) async throws -> RemoteRecord {
        try await mapError {
            let response = try await client.getRecord(recordID: try data(fromHex: recordID))
            return mapRecord(response.record)
        }
    }

    func transferStatus(deviceID: String, transferID: String) async throws -> TransferStatusSummary {
        try await mapError {
            let response = try await client.transferStatus(
                deviceID: try data(fromHex: deviceID),
                transferID: try data(fromHex: transferID)
            )
            return TransferStatusSummary(
                nextChunkIndex: Int(response.nextChunkIndex),
                nextChunkOffset: response.nextChunkOffset
            )
        }
    }

    func download(record: RemoteRecord) async throws -> DownloadSummary {
        try await mapError {
            let fileName = record.fileName.isEmpty ? "descarga.bin" : record.fileName
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("MDTP-\(UUID().uuidString)-\(fileName)")

            let result = try await client.download(
                record: try clientRecord(from: record),
                to: destination
            )
            return DownloadSummary(
                fileName: result.destination.lastPathComponent,
                fileSize: result.fileSize,
                destination: result.destination,
                sha256: result.sha256
            )
        }
    }

    func fetchPhotoHashes(deviceID: String) async throws -> Set<Data> {
        let records = try await fetchPhotoRecords(deviceID: deviceID)
        return Set(records.map(\.sha256))
    }

    func fetchPhotoRecords(deviceID: String) async throws -> [RemoteRecord] {
        try await mapError {
            let deviceIDData = try data(fromHex: deviceID)
            var records: [RemoteRecord] = []
            var pageToken = ""

            repeat {
                var request = SearchRecordsRequest()
                request.deviceID = deviceIDData
                request.dataCategory = MDTPDataCategory.photo
                request.pageSize = 100
                request.sortBy = "created_at"
                request.descending = true
                request.pageToken = pageToken

                let response = try await client.searchRecords(request)
                records.append(contentsOf: response.records.map(mapRecord))
                pageToken = response.nextPageToken
            } while !pageToken.isEmpty

            return records
        }
    }

    func upload(photo: Photo, deviceID: String) async throws -> UploadSummary {
        try await mapError {
            let result = try await client.upload(
                fileURL: photo.url,
                deviceID: try data(fromHex: deviceID),
                fileName: photo.fileName,
                contentType: "image/jpeg",
                dataCategory: MDTPDataCategory.photo
            )
            return UploadSummary(
                deviceID: deviceID,
                transferID: hex(result.transferID),
                fileName: photo.fileName,
                success: result.success
            )
        }
    }

    func uploadVideo(
        fileURL: URL,
        deviceID: String,
        fileName: String,
        contentType: String
    ) async throws -> UploadSummary {
        try await mapError {
            let result = try await client.upload(
                fileURL: fileURL,
                deviceID: try data(fromHex: deviceID),
                fileName: fileName,
                contentType: contentType,
                dataCategory: MDTPDataCategory.video
            )
            return UploadSummary(
                deviceID: deviceID,
                transferID: hex(result.transferID),
                fileName: fileName,
                success: result.success
            )
        }
    }

    private func mapRecord(_ record: RecordInfo) -> RemoteRecord {
        RemoteRecord(
            id: hex(record.recordID),
            fileName: record.fileName,
            fileSize: record.fileSize,
            contentType: record.contentType,
            dataCategory: record.dataCategory,
            sha256: record.sha256
        )
    }

    private func clientRecord(from record: RemoteRecord) throws -> RecordInfo {
        var value = RecordInfo()
        value.recordID = try data(fromHex: record.id)
        value.fileName = record.fileName
        value.fileSize = record.fileSize
        value.contentType = record.contentType
        value.dataCategory = record.dataCategory
        value.sha256 = record.sha256
        return value
    }

    private func clientInstanceID() -> Data {
        if let saved = userDefaults.data(forKey: Keys.clientInstanceID), saved.count == 16 {
            return saved
        }
        let identifier = MDTPClient.makeIdentifier()
        userDefaults.set(identifier, forKey: Keys.clientInstanceID)
        return identifier
    }

    private func persist(deviceID: Data) {
        userDefaults.set(deviceID, forKey: Keys.deviceID)
    }

    private func loadDeviceID() -> String? {
        guard let data = userDefaults.data(forKey: Keys.deviceID), data.count == 16 else {
            return nil
        }
        return hex(data)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func data(fromHex string: String) throws -> Data {
        guard string.count == 32, let data = Data(hexString: string) else {
            throw APITestError(message: "Identificador hexadecimal inválido: \(string)")
        }
        return data
    }

    private func mapError<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as APITestError {
            throw error
        } catch let error as MDTPError {
            throw APITestError(message: error.description)
        } catch {
            throw APITestError(message: error.localizedDescription)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(String(hex[index..<next]), radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
