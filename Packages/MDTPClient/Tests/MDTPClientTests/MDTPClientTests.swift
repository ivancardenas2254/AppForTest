import Foundation
import SwiftProtobuf
import Testing
@testable import MDTPClient

struct MockTransport: MDTPTransport {
    let handler: @Sendable (Data, URL) async throws -> MDTPHTTPResponse
    let getHandler: @Sendable (URL, String) async throws -> MDTPHTTPResponse

    init(
        handler: @escaping @Sendable (Data, URL) async throws -> MDTPHTTPResponse,
        getHandler: @escaping @Sendable (URL, String) async throws -> MDTPHTTPResponse = { _, _ in
            MDTPHTTPResponse(statusCode: 501, data: Data())
        }
    ) {
        self.handler = handler
        self.getHandler = getHandler
    }

    func send(_ body: Data, to url: URL) async throws -> MDTPHTTPResponse {
        try await handler(body, url)
    }

    func get(_ url: URL, accept: String) async throws -> MDTPHTTPResponse {
        try await getHandler(url, accept)
    }
}

actor RequestLog {
    private(set) var paths: [String] = []

    func append(_ url: URL) {
        paths.append(url.path)
    }
}

actor ChunkStore {
    private(set) var chunks: [(index: UInt32, offset: UInt64, data: Data)] = []

    func append(index: UInt32, offset: UInt64, data: Data) {
        chunks.append((index, offset, data))
    }
}

let baseURL = URL(string: "https://example.test")!

func makeClient(
    _ handler: @escaping @Sendable (Data, URL) async throws -> MDTPHTTPResponse
) -> MDTPClient {
    MDTPClient(
        configuration: MDTPConfiguration(baseURL: baseURL),
        transport: MockTransport(handler: handler)
    )
}

func ok(_ message: SwiftProtobuf.Message) throws -> MDTPHTTPResponse {
    MDTPHTTPResponse(statusCode: 200, data: try message.serializedData())
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MDTPClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SHA-256")
struct SHA256Tests {
    @Test("Vectores conocidos")
    func knownVectors() {
        #expect(hex(MDTPSHA256.hash(Data())) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(MDTPSHA256.hash(Data("abc".utf8))) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(MDTPSHA256.hash(Data("The quick brown fox jumps over the lazy dog".utf8))) ==
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    @Test("Actualizacion incremental")
    func incremental() {
        let bytes = [UInt8](repeating: 0x61, count: 1_000_000)
        var context = MDTPSHA256.Context()
        for start in stride(from: 0, to: bytes.count, by: 997) {
            let end = min(start + 997, bytes.count)
            context.update(Array(bytes[start..<end]))
        }
        #expect(hex(context.finalize()) ==
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("Hash de archivo")
    func fileHash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("sample.bin")
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        try content.write(to: file)

        let fileHash = try MDTPSHA256.hash(fileAt: file)
        #expect(fileHash == MDTPSHA256.hash(content))
    }
}

@Suite("Cliente")
struct ClientTests {
    @Test("Registro usa /v1/devices/register y el mensaje correcto")
    func registerDevice() async throws {
        let log = RequestLog()
        let deviceID = Data(repeating: 0x01, count: 16)
        let clientInstanceID = Data(repeating: 0x02, count: 16)

        let client = makeClient { data, url in
            await log.append(url)
            let request = try RegisterDeviceRequest(serializedBytes: data)
            #expect(request.clientInstanceID == clientInstanceID)
            #expect(request.deviceName == "iPhone")

            var response = RegisterDeviceResponse()
            response.deviceID = deviceID
            return try ok(response)
        }

        let response = try await client.registerDevice(
            clientInstanceID: clientInstanceID,
            deviceName: "iPhone"
        )

        #expect(response.deviceID == deviceID)
        #expect(await log.paths == ["/v1/devices/register"])
    }

    @Test("Un estado HTTP no exitoso se informa con su codigo")
    func httpError() async throws {
        let client = makeClient { _, _ in
            MDTPHTTPResponse(statusCode: 409, data: Data())
        }

        do {
            _ = try await client.registerDevice()
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .httpStatus(409) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("Protobuf invalido en HTTP 200")
    func invalidProtobuf() async throws {
        let client = makeClient { _, _ in
            MDTPHTTPResponse(statusCode: 200, data: Data([0xff, 0xff, 0xff]))
        }

        do {
            _ = try await client.listDevices()
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("Un SHA-256 de subida debe medir 32 bytes")
    func uploadHashLength() async throws {
        let client = makeClient { _, _ in
            Issue.record("No se esperaba una solicitud de red")
            return MDTPHTTPResponse(statusCode: 200, data: Data())
        }

        do {
            _ = try await client.transferBegin(
                deviceID: Data(repeating: 0x01, count: 16),
                transferID: Data(repeating: 0x02, count: 16),
                fileName: "file.bin",
                fileSize: 1,
                fileHash: Data(repeating: 0x03, count: 16)
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidHashLength(let expected, let actual) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
            #expect(expected == 32)
            #expect(actual == 16)
        }
    }
}

@Suite("Transferencia")
struct FileTransferTests {
    @Test("Subida por bloques")
    func upload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("hello mdtp".utf8)
        let file = directory.appendingPathComponent("upload.txt")
        try content.write(to: file)

        let chunkStore = ChunkStore()
        let deviceID = Data(repeating: 0x01, count: 16)
        let transferID = Data(repeating: 0x02, count: 16)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                let begin = try TransferBeginRequest(serializedBytes: data)
                #expect(begin.fileSize == UInt64(content.count))
                #expect(begin.fileHash == MDTPSHA256.hash(content))
                #expect(begin.fileName == "upload.txt")
                #expect(begin.transferID == transferID)

                var result = TransferBeginResponse()
                result.nextChunkIndex = 0
                result.nextChunkOffset = 0
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                let chunk = try TransferChunkRequest(serializedBytes: data)
                await chunkStore.append(
                    index: chunk.chunkIndex,
                    offset: chunk.chunkOffset,
                    data: chunk.chunkData
                )
                var result = TransferChunkResponse()
                result.nextChunkIndex = chunk.chunkIndex + 1
                result.nextChunkOffset = chunk.chunkOffset + UInt64(chunk.chunkData.count)
                return try ok(result)

            case "/v1/transfers/commit":
                var result = TransferCommitResponse()
                result.success = true
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.upload(
            fileURL: file,
            deviceID: deviceID,
            transferID: transferID,
            maxChunkSize: 4
        )

        #expect(result.success)
        #expect(result.transferID == transferID)
        let chunks = await chunkStore.chunks
        #expect(chunks.count == 3)
        #expect(chunks.map(\.data).reduce(into: Data()) { $0.append($1) } == content)
        #expect(chunks.map(\.index) == [0, 1, 2])
        #expect(chunks.map(\.offset) == [0, 4, 8])
    }

    @Test("Subida reanuda desde el offset del servidor")
    func uploadResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("0123456789".utf8)
        let file = directory.appendingPathComponent("resume.txt")
        try content.write(to: file)

        let chunkStore = ChunkStore()
        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                let begin = try TransferBeginRequest(serializedBytes: data)
                #expect(begin.fileSize == UInt64(content.count))
                #expect(begin.fileHash == MDTPSHA256.hash(content))

                var result = TransferBeginResponse()
                result.nextChunkIndex = 1
                result.nextChunkOffset = 4
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                let chunk = try TransferChunkRequest(serializedBytes: data)
                await chunkStore.append(
                    index: chunk.chunkIndex,
                    offset: chunk.chunkOffset,
                    data: chunk.chunkData
                )
                var result = TransferChunkResponse()
                result.nextChunkIndex = chunk.chunkIndex + 1
                result.nextChunkOffset = chunk.chunkOffset + UInt64(chunk.chunkData.count)
                return try ok(result)

            case "/v1/transfers/commit":
                var result = TransferCommitResponse()
                result.success = true
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.upload(
            fileURL: file,
            deviceID: Data(repeating: 0x01, count: 16),
            transferID: Data(repeating: 0x02, count: 16),
            maxChunkSize: 4
        )

        #expect(result.success)
        let chunks = await chunkStore.chunks
        #expect(chunks.count == 2)
        #expect(chunks.map(\.index) == [1, 2])
        #expect(chunks.map(\.offset) == [4, 8])
        #expect(chunks.map(\.data) == [
            content.subdata(in: 4..<8),
            content.subdata(in: 8..<10),
        ])
    }

    @Test("Subida de archivo vacio")
    func uploadEmptyFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                let begin = try TransferBeginRequest(serializedBytes: data)
                #expect(begin.fileSize == 0)
                #expect(begin.fileHash == MDTPSHA256.hash(Data()))

                var result = TransferBeginResponse()
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                Issue.record("No se esperaba un bloque")
                return MDTPHTTPResponse(statusCode: 500, data: Data())

            case "/v1/transfers/commit":
                var result = TransferCommitResponse()
                result.success = true
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.upload(
            fileURL: file,
            deviceID: Data(repeating: 0x01, count: 16),
            transferID: Data(repeating: 0x02, count: 16)
        )

        #expect(result.success)
    }

    @Test("El commit fallido se informa como error")
    func uploadCommitFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("test".utf8)
        let file = directory.appendingPathComponent("commit.bin")
        try content.write(to: file)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                var result = TransferBeginResponse()
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                let chunk = try TransferChunkRequest(serializedBytes: data)
                var result = TransferChunkResponse()
                result.nextChunkIndex = chunk.chunkIndex + 1
                result.nextChunkOffset = chunk.chunkOffset + UInt64(chunk.chunkData.count)
                return try ok(result)

            case "/v1/transfers/commit":
                var result = TransferCommitResponse()
                result.success = false
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.upload(
                fileURL: file,
                deviceID: Data(repeating: 0x01, count: 16),
                transferID: Data(repeating: 0x02, count: 16)
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .transferCommitFailed = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("La subida rechaza un offset de confirmacion incorrecto")
    func uploadRejectsWrongNextOffset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("offset.bin")
        try Data("test".utf8).write(to: file)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                var result = TransferBeginResponse()
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                let chunk = try TransferChunkRequest(serializedBytes: data)
                var result = TransferChunkResponse()
                result.nextChunkIndex = chunk.chunkIndex + 1
                result.nextChunkOffset = chunk.chunkOffset + UInt64(chunk.chunkData.count) + 1
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.upload(
                fileURL: file,
                deviceID: Data(repeating: 0x01, count: 16),
                transferID: Data(repeating: 0x02, count: 16)
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("La subida rechaza un indice de confirmacion incorrecto")
    func uploadRejectsWrongNextIndex() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("index.bin")
        try Data("test".utf8).write(to: file)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/transfers":
                var result = TransferBeginResponse()
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/transfers/chunk":
                let chunk = try TransferChunkRequest(serializedBytes: data)
                var result = TransferChunkResponse()
                result.nextChunkIndex = chunk.chunkIndex + 2
                result.nextChunkOffset = chunk.chunkOffset + UInt64(chunk.chunkData.count)
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.upload(
                fileURL: file,
                deviceID: Data(repeating: 0x01, count: 16),
                transferID: Data(repeating: 0x02, count: 16)
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("Descarga por bloques y verificacion SHA-256")
    func download() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("download content".utf8)
        let destination = directory.appendingPathComponent("download.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = UInt64(content.count)
                result.sha256 = MDTPSHA256.hash(content)
                result.maxChunkSize = 5
                result.nextChunkIndex = 0
                result.nextChunkOffset = 0
                return try ok(result)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                let start = Int(chunk.chunkOffset)
                let end = min(start + Int(chunk.requestedLength), content.count)

                var result = DownloadChunkResponse()
                result.chunkIndex = chunk.chunkIndex
                result.chunkOffset = chunk.chunkOffset
                result.chunkData = content.subdata(in: start..<end)
                result.isLastChunk = end == content.count
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.download(
            recordID: Data(repeating: 0x04, count: 16),
            to: destination,
            maxChunkSize: 5
        )

        let downloaded = try Data(contentsOf: destination)
        #expect(downloaded == content)
        #expect(result.sha256 == MDTPSHA256.hash(content))
        #expect(result.fileSize == UInt64(content.count))
    }

    @Test("Descarga reanuda desde un archivo parcial")
    func downloadResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("0123456789".utf8)
        let destination = directory.appendingPathComponent("resume-download.bin")
        try content.prefix(4).write(to: destination)
        let downloadID = Data(repeating: 0x03, count: 16)
        let log = RequestLog()

        let client = makeClient { data, url in
            await log.append(url)

            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = UInt64(content.count)
                result.sha256 = MDTPSHA256.hash(content)
                result.maxChunkSize = 4
                result.nextChunkIndex = 1
                result.nextChunkOffset = 4
                return try ok(result)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                let start = Int(chunk.chunkOffset)
                let end = min(start + Int(chunk.requestedLength), content.count)

                var result = DownloadChunkResponse()
                result.chunkIndex = chunk.chunkIndex
                result.chunkOffset = chunk.chunkOffset
                result.chunkData = content.subdata(in: start..<end)
                result.isLastChunk = end == content.count
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        _ = try await client.download(
            recordID: Data(repeating: 0x04, count: 16),
            to: destination,
            maxChunkSize: 4
        )

        let downloaded = try Data(contentsOf: destination)
        #expect(downloaded == content)
        #expect(await log.paths == ["/v1/downloads/begin", "/v1/downloads/chunk", "/v1/downloads/chunk"])
    }

    @Test("Descarga de archivo vacio")
    func downloadEmptyFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("empty-download.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { _, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = 0
                result.sha256 = MDTPSHA256.hash(Data())
                result.maxChunkSize = 4
                return try ok(result)

            default:
                Issue.record("No se esperaba un bloque")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        let result = try await client.download(
            recordID: Data(repeating: 0x04, count: 16),
            to: destination
        )

        let downloaded = try Data(contentsOf: destination)
        #expect(downloaded.isEmpty)
        #expect(result.fileSize == 0)
        #expect(result.sha256 == MDTPSHA256.hash(Data()))
    }

    @Test("La descarga rechaza un bloque mayor que el solicitado")
    func downloadRejectsOversizedChunk() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("0123456789".utf8)
        let destination = directory.appendingPathComponent("oversized.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = UInt64(content.count)
                result.sha256 = MDTPSHA256.hash(content)
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                var result = DownloadChunkResponse()
                result.chunkIndex = chunk.chunkIndex
                result.chunkOffset = chunk.chunkOffset
                result.chunkData = content.prefix(Int(chunk.requestedLength) + 1)
                result.isLastChunk = false
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.download(
                recordID: Data(repeating: 0x04, count: 16),
                to: destination,
                maxChunkSize: 4
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("La descarga rechaza un SHA-256 de longitud incorrecta")
    func downloadRejectsInvalidHashLength() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("bad-hash.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { _, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = 10
                result.sha256 = Data(repeating: 0x01, count: 16)
                result.maxChunkSize = 4
                return try ok(result)

            default:
                Issue.record("No se esperaba un bloque")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.download(
                recordID: Data(repeating: 0x04, count: 16),
                to: destination
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidHashLength(let expected, let actual) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
            #expect(expected == 32)
            #expect(actual == 16)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("La descarga detecta un SHA-256 incorrecto")
    func downloadDetectsHashMismatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = Data("hash mismatch".utf8)
        let destination = directory.appendingPathComponent("mismatch.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = UInt64(content.count)
                result.sha256 = Data(repeating: 0x00, count: 32)
                result.maxChunkSize = 5
                return try ok(result)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                let start = Int(chunk.chunkOffset)
                let end = min(start + Int(chunk.requestedLength), content.count)

                var result = DownloadChunkResponse()
                result.chunkIndex = chunk.chunkIndex
                result.chunkOffset = chunk.chunkOffset
                result.chunkData = content.subdata(in: start..<end)
                result.isLastChunk = end == content.count
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.download(
                recordID: Data(repeating: 0x04, count: 16),
                to: destination,
                maxChunkSize: 5
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .hashMismatch = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("La descarga rechaza un bloque vacio antes del final")
    func downloadRejectsEmptyChunk() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("empty-chunk.bin")
        let downloadID = Data(repeating: 0x03, count: 16)

        let client = makeClient { data, url in
            switch url.path {
            case "/v1/downloads/begin":
                var result = DownloadBeginResponse()
                result.downloadID = downloadID
                result.fileSize = 10
                result.sha256 = MDTPSHA256.hash(Data(repeating: 0x01, count: 10))
                result.maxChunkSize = 4
                return try ok(result)

            case "/v1/downloads/chunk":
                let chunk = try DownloadChunkRequest(serializedBytes: data)
                var result = DownloadChunkResponse()
                result.chunkIndex = chunk.chunkIndex
                result.chunkOffset = chunk.chunkOffset
                result.chunkData = Data()
                result.isLastChunk = false
                return try ok(result)

            default:
                Issue.record("Ruta inesperada: \(url.path)")
                return MDTPHTTPResponse(statusCode: 404, data: Data())
            }
        }

        do {
            _ = try await client.download(
                recordID: Data(repeating: 0x04, count: 16),
                to: destination
            )
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }
}
