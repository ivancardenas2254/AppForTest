import Foundation
import SwiftProtobuf
import Testing
@testable import MDTPClient

@Suite("Consultas y descargas")
struct QueriesTests {
    @Test("listDevices envia filtros de paginacion")
    func listDevices() async throws {
        let log = RequestLog()
        let deviceID = Data(repeating: 0x01, count: 16)

        let client = makeClient { data, url in
            await log.append(url)
            let request = try ListDevicesRequest(serializedBytes: data)
            #expect(request.pageSize == 17)
            #expect(request.pageToken == "page-2")

            var device = DeviceInfo()
            device.deviceID = deviceID
            device.deviceName = "Uno"
            var response = ListDevicesResponse()
            response.devices = [device]
            return try ok(response)
        }

        let response = try await client.listDevices(pageSize: 17, pageToken: "page-2")

        #expect(response.devices.map(\.deviceName) == ["Uno"])
        #expect(await log.paths == ["/v1/devices/list"])
    }

    @Test("searchRecords conserva todos los filtros")
    func searchRecords() async throws {
        let log = RequestLog()
        let deviceID = Data(repeating: 0x03, count: 16)

        var filter = SearchRecordsRequest()
        filter.deviceID = deviceID
        filter.applicationID = "com.example.app"
        filter.dataCategory = "photo"
        filter.fileNameContains = "IMG"
        filter.createdFromUnixMs = 100
        filter.createdToUnixMs = 200
        filter.contentTypePrefix = "image/"
        filter.pageSize = 25
        filter.pageToken = "page-2"
        filter.sortBy = "file_name"
        filter.descending = true
        let expectedFilter = filter

        let client = makeClient { data, url in
            await log.append(url)
            let request = try SearchRecordsRequest(serializedBytes: data)
            #expect(request == expectedFilter)

            var record = RecordInfo()
            record.recordID = Data([0x01])
            record.sha256 = MDTPSHA256.hash(Data([0x01]))
            var response = SearchRecordsResponse()
            response.records = [record]
            return try ok(response)
        }

        let response = try await client.searchRecords(filter)

        #expect(response.records.map(\.recordID) == [Data([0x01])])
        #expect(await log.paths == ["/v1/records/search"])
    }

    @Test("getRecord rechaza un registro distinto al solicitado")
    func getRecordMismatch() async throws {
        let requestedID = Data([0x01])

        let client = makeClient { _, url in
            #expect(url.path == "/v1/records/get")

            var record = RecordInfo()
            record.recordID = Data([0x02])
            record.sha256 = MDTPSHA256.hash(Data([0x02]))

            var response = GetRecordResponse()
            response.record = record
            return try ok(response)
        }

        do {
            _ = try await client.getRecord(recordID: requestedID)
            Issue.record("Se esperaba un error de validacion")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("download(record:) rechaza registros sin contenido")
    func downloadRejectsUnavailableContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("unavailable.bin")

        var record = RecordInfo()
        record.recordID = Data([0x01])
        record.sha256 = MDTPSHA256.hash(Data([0x01]))
        record.contentAvailable = false

        let client = makeClient { _, _ in
            Issue.record("No se esperaba una solicitud de red")
            return MDTPHTTPResponse(statusCode: 500, data: Data())
        }

        do {
            _ = try await client.download(record: record, to: destination)
            Issue.record("Se esperaba un error de contenido no disponible")
        } catch let error as MDTPError {
            guard case .contentUnavailable = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("download(record:) descarga usando los metadatos")
    func downloadRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("record.bin")

        let content = Data("contenido por registro".utf8)
        let contentHash = MDTPSHA256.hash(content)
        let downloadID = Data(repeating: 0x04, count: 16)
        let expectedRecordID = Data([0x01])

        var record = RecordInfo()
        record.recordID = expectedRecordID
        record.fileSize = UInt64(content.count)
        record.sha256 = contentHash
        record.contentAvailable = true

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                let request = try DownloadBeginRequest(serializedBytes: data)
                #expect(request.recordID == expectedRecordID)

                var response = DownloadBeginResponse()
                response.downloadID = downloadID
                response.fileSize = UInt64(content.count)
                response.sha256 = contentHash
                response.maxChunkSize = 4
                return try ok(response)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                let start = Int(chunk.chunkOffset)
                let end = min(start + Int(chunk.requestedLength), content.count)

                var response = DownloadChunkResponse()
                response.chunkIndex = chunk.chunkIndex
                response.chunkOffset = chunk.chunkOffset
                response.chunkData = content.subdata(in: start..<end)
                response.isLastChunk = end == content.count
                return try ok(response)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.download(
            record: record,
            to: destination,
            maxChunkSize: 4
        )

        #expect(result.recordID == expectedRecordID)
        #expect(result.sha256 == contentHash)
        #expect(try Data(contentsOf: destination) == content)
    }

    @Test("download(record:) verifica el SHA-256 de los metadatos")
    func downloadRecordHashMismatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("record.bin")

        let content = Data("contenido".utf8)
        let contentHash = MDTPSHA256.hash(content)
        let expectedRecordID = Data([0x01])

        var record = RecordInfo()
        record.recordID = expectedRecordID
        record.fileSize = UInt64(content.count)
        record.sha256 = MDTPSHA256.hash(Data("otro contenido".utf8))
        record.contentAvailable = true

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                var response = DownloadBeginResponse()
                response.downloadID = Data(repeating: 0x04, count: 16)
                response.fileSize = UInt64(content.count)
                response.sha256 = contentHash
                response.maxChunkSize = 4
                return try ok(response)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                let start = Int(chunk.chunkOffset)
                let end = min(start + Int(chunk.requestedLength), content.count)

                var response = DownloadChunkResponse()
                response.chunkIndex = chunk.chunkIndex
                response.chunkOffset = chunk.chunkOffset
                response.chunkData = content.subdata(in: start..<end)
                response.isLastChunk = end == content.count
                return try ok(response)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.download(record: record, to: destination, maxChunkSize: 4)
            Issue.record("Se esperaba un error de integridad")
        } catch let error as MDTPError {
            guard case .hashMismatch = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }
}
