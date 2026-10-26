import Foundation
import SwiftProtobuf
import Testing
@testable import MDTPClient

@Suite("Conformidad v1.0")
struct ConformanceTests {
    @Test("Cada operacion usa su endpoint y su mensaje Protobuf")
    func allEndpoints() async throws {
        let deviceID = Data(repeating: 0x01, count: 16)
        let transferID = Data(repeating: 0x02, count: 16)
        let recordID = Data(repeating: 0x03, count: 16)
        let downloadID = Data(repeating: 0x04, count: 16)
        let content = Data("mdtp".utf8)
        let contentHash = MDTPSHA256.hash(content)
        let log = RequestLog()

        let client = makeClient { data, url in
            await log.append(url)

            switch url.path {
            case "/v1/devices/register":
                let request = try RegisterDeviceRequest(serializedBytes: data)
                #expect(request.deviceName == "Test")
                var response = RegisterDeviceResponse()
                response.deviceID = deviceID
                return try ok(response)

            case "/v1/transfers":
                let request = try TransferBeginRequest(serializedBytes: data)
                #expect(request.transferID == transferID)
                #expect(request.fileHash == contentHash)
                var response = TransferBeginResponse()
                response.maxChunkSize = UInt32(content.count)
                return try ok(response)

            case "/v1/transfers/chunk":
                let request = try TransferChunkRequest(serializedBytes: data)
                #expect(request.chunkData == content)
                var response = TransferChunkResponse()
                response.nextChunkIndex = request.chunkIndex + 1
                response.nextChunkOffset = request.chunkOffset + UInt64(request.chunkData.count)
                return try ok(response)

            case "/v1/transfers/status":
                let request = try TransferStatusRequest(serializedBytes: data)
                #expect(request.transferID == transferID)
                var response = TransferStatusResponse()
                response.completed = true
                return try ok(response)

            case "/v1/transfers/commit":
                let request = try TransferCommitRequest(serializedBytes: data)
                #expect(request.transferID == transferID)
                var response = TransferCommitResponse()
                response.success = true
                return try ok(response)

            case "/v1/devices/list":
                _ = try ListDevicesRequest(serializedBytes: data)
                return try ok(ListDevicesResponse())

            case "/v1/records/search":
                _ = try SearchRecordsRequest(serializedBytes: data)
                return try ok(SearchRecordsResponse())

            case "/v1/records/get":
                let request = try GetRecordRequest(serializedBytes: data)
                #expect(request.recordID == recordID)
                var record = RecordInfo()
                record.recordID = recordID
                record.fileSize = UInt64(content.count)
                record.sha256 = contentHash
                record.contentAvailable = true
                var response = GetRecordResponse()
                response.record = record
                return try ok(response)

            case "/v1/downloads/begin":
                let request = try DownloadBeginRequest(serializedBytes: data)
                #expect(request.recordID == recordID)
                var response = DownloadBeginResponse()
                response.downloadID = downloadID
                response.fileSize = UInt64(content.count)
                response.sha256 = contentHash
                response.maxChunkSize = UInt32(content.count)
                return try ok(response)

            case "/v1/downloads/chunk":
                let request = try DownloadChunkRequest(serializedBytes: data)
                #expect(request.downloadID == downloadID)
                var response = DownloadChunkResponse()
                response.chunkIndex = request.chunkIndex
                response.chunkOffset = request.chunkOffset
                response.chunkData = content
                response.isLastChunk = true
                return try ok(response)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        _ = try await client.registerDevice(clientInstanceID: deviceID, deviceName: "Test")
        _ = try await client.transferBegin(
            deviceID: deviceID,
            transferID: transferID,
            fileName: "file.bin",
            fileSize: UInt64(content.count),
            fileHash: contentHash,
            contentType: "application/octet-stream",
            applicationID: "com.example",
            dataCategory: MDTPDataCategory.document,
            sourceRecordID: "source"
        )
        _ = try await client.transferChunk(
            deviceID: deviceID,
            transferID: transferID,
            chunkIndex: 0,
            chunkOffset: 0,
            chunkData: content
        )
        _ = try await client.transferStatus(deviceID: deviceID, transferID: transferID)
        _ = try await client.transferCommit(deviceID: deviceID, transferID: transferID)
        _ = try await client.listDevices(pageSize: 10, pageToken: "token")
        _ = try await client.searchRecords(SearchRecordsRequest())
        _ = try await client.getRecord(recordID: recordID)
        _ = try await client.downloadBegin(recordID: recordID)
        _ = try await client.downloadChunk(
            downloadID: downloadID,
            chunkIndex: 0,
            chunkOffset: 0,
            requestedLength: UInt32(content.count)
        )

        #expect(await log.paths == [
            "/v1/devices/register",
            "/v1/transfers",
            "/v1/transfers/chunk",
            "/v1/transfers/status",
            "/v1/transfers/commit",
            "/v1/devices/list",
            "/v1/records/search",
            "/v1/records/get",
            "/v1/downloads/begin",
            "/v1/downloads/chunk",
        ])
    }
}
