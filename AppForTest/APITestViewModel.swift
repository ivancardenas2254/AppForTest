import Combine
import Foundation
import UIKit
import MDTPClient

@MainActor
final class APITestViewModel: ObservableObject {
    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var deviceID: Data?
    @Published private(set) var records: [RecordInfo] = []
    @Published private(set) var lastUpload: MDTPUploadResult?

    let baseURL: URL
    private let client: MDTPClient
    private static let deviceIDKey = "mdtp.deviceID"
    private static let clientInstanceIDKey = "mdtp.clientInstanceID"

    init() {
        let url = URL(string: "http://192.168.1.143:8080")!
        baseURL = url
        client = MDTPClient(configuration: MDTPConfiguration(baseURL: url))
        if let saved = UserDefaults.standard.data(forKey: Self.deviceIDKey), saved.count == 16 {
            deviceID = saved
        }
    }

    var deviceLabel: String {
        guard let deviceID else { return "sin registrar" }
        return hex(deviceID)
    }

    var recordsLabel: String {
        "\(records.count)"
    }

    func clearLog() {
        log.removeAll()
    }

    func checkConnection() async {
        await perform("Probar conexión (listDevices)") {
            let response = try await client.listDevices(pageSize: 1)
            append("Conexión OK · \(response.devices.count) dispositivo(s)")
        }
    }

    func checkHealth() async {
        await perform("Health GET /health") {
            let health = try await client.health()
            append("status: \(health.status)\(health.isHealthy ? " · saludable" : " · no saludable")")
        }
    }

    func registerDevice() async {
        await perform("Registrar dispositivo") {
            let id = try await registerOnServer()
            append("deviceID: \(hex(id))")
        }
    }

    func listDevices() async {
        await perform("Listar dispositivos") {
            let response = try await client.listDevices(pageSize: 50)
            if response.devices.isEmpty {
                append("Sin dispositivos.")
            } else {
                for device in response.devices {
                    let name = device.deviceName.isEmpty ? "(sin nombre)" : device.deviceName
                    append("\(name) · \(hex(device.deviceID)) · \(device.platform) · \(device.recordCount) registros")
                }
            }
        }
    }

    func searchPhotos() async {
        await perform("Buscar fotos") {
            var request = SearchRecordsRequest()
            request.dataCategory = MDTPDataCategory.photo
            request.pageSize = 50
            request.sortBy = "created_at"
            request.descending = true
            let response = try await client.searchRecords(request)
            records = response.records
            append("\(response.records.count) registro(s) · total \(response.totalCount)")
            for record in response.records.prefix(10) {
                append("\(record.fileName) · \(record.fileSize) bytes · \(hex(record.recordID))")
            }
        }
    }

    func getFirstRecord() async {
        await perform("Obtener primer registro") {
            guard let record = records.first else {
                append("No hay registros. Buscá fotos primero.")
                return
            }
            let response = try await client.getRecord(recordID: record.recordID)
            append("OK · \(response.record.fileName) · \(response.record.contentType)")
        }
    }

    func uploadLatestPhoto() async {
        await perform("Subir última foto") {
            guard let fileURL = PhotoStore.listCaptures().first else {
                append("No hay fotos guardadas.")
                return
            }
            let id = try await refreshDeviceID()
            let result = try await client.upload(
                fileURL: fileURL,
                deviceID: id,
                fileName: fileURL.lastPathComponent,
                contentType: "image/jpeg",
                dataCategory: MDTPDataCategory.photo
            )
            lastUpload = result
            append("Subida OK · \(fileURL.lastPathComponent) · transferID \(hex(result.transferID))")
        }
    }

    func syncPhotos() async {
        await perform("Sincronizar fotos") {
            let captures = PhotoStore.listCaptures()
            guard !captures.isEmpty else {
                append("No hay fotos guardadas.")
                return
            }

            let id = try await refreshDeviceID()
            let existing = try await fetchPhotoRecords(deviceID: id)
            var knownHashes = Set(existing.map(\.sha256))
            var uploaded = 0
            var skipped = 0
            var failed = 0

            for fileURL in captures.reversed() {
                let hash: Data
                do {
                    hash = try MDTPSHA256.hash(fileAt: fileURL)
                } catch {
                    failed += 1
                    append("✗ \(fileURL.lastPathComponent): \(describe(error))")
                    continue
                }

                if knownHashes.contains(hash) {
                    skipped += 1
                    continue
                }

                do {
                    let result = try await client.upload(
                        fileURL: fileURL,
                        deviceID: id,
                        fileName: fileURL.lastPathComponent,
                        contentType: "image/jpeg",
                        dataCategory: MDTPDataCategory.photo
                    )
                    lastUpload = result
                    knownHashes.insert(hash)
                    uploaded += 1
                    append("↑ \(fileURL.lastPathComponent)")
                } catch {
                    failed += 1
                    append("✗ \(fileURL.lastPathComponent): \(describe(error))")
                }
            }

            records = try await fetchPhotoRecords(deviceID: id)
            append("Sincronización: \(uploaded) subida(s), \(skipped) existente(s), \(failed) fallida(s) · \(records.count) en el servidor")
        }
    }

    func transferStatus() async {
        await perform("Estado de última transferencia") {
            guard let upload = lastUpload else {
                append("No hay transferencia. Subí una foto primero.")
                return
            }
            let response = try await client.transferStatus(
                deviceID: upload.deviceID,
                transferID: upload.transferID
            )
            append("nextChunkIndex: \(response.nextChunkIndex) · nextChunkOffset: \(response.nextChunkOffset)")
        }
    }

    func downloadFirstRecord() async {
        await perform("Descargar primer registro") {
            guard let record = records.first else {
                append("No hay registros. Buscá fotos primero.")
                return
            }
            let fileName = record.fileName.isEmpty ? "descarga.bin" : record.fileName
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("MDTP-\(UUID().uuidString)-\(fileName)")
            let result = try await client.download(record: record, to: destination)
            append("Descarga OK · \(result.destination.lastPathComponent) · \(result.fileSize) bytes")
        }
    }

    private func registerOnServer() async throws -> Data {
        let response = try await client.registerDevice(
            clientInstanceID: clientInstanceID(),
            deviceName: UIDevice.current.name
        )
        deviceID = response.deviceID
        UserDefaults.standard.set(response.deviceID, forKey: Self.deviceIDKey)
        return response.deviceID
    }

    private func refreshDeviceID() async throws -> Data {
        let previous = deviceID
        let id = try await registerOnServer()
        if previous != id {
            append("Dispositivo · \(hex(id))")
        }
        return id
    }

    private func clientInstanceID() -> Data {
        if let saved = UserDefaults.standard.data(forKey: Self.clientInstanceIDKey), saved.count == 16 {
            return saved
        }
        let id = MDTPClient.makeIdentifier()
        UserDefaults.standard.set(id, forKey: Self.clientInstanceIDKey)
        return id
    }

    private func fetchPhotoRecords(deviceID: Data) async throws -> [RecordInfo] {
        var all: [RecordInfo] = []
        var pageToken = ""

        repeat {
            var request = SearchRecordsRequest()
            request.deviceID = deviceID
            request.dataCategory = MDTPDataCategory.photo
            request.pageSize = 100
            request.sortBy = "created_at"
            request.descending = true
            request.pageToken = pageToken

            let response = try await client.searchRecords(request)
            all.append(contentsOf: response.records)
            pageToken = response.nextPageToken
        } while !pageToken.isEmpty

        return all
    }

    private func perform(_ title: String, operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        append("→ \(title)")
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            append("✗ \(describe(error))")
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? MDTPError {
            return error.description
        }
        return error.localizedDescription
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
