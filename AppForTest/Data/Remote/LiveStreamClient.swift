import Foundation
import MDTPClient  // for MDTPSHA256

// MARK: - LiveStreamClient
/// Lightweight HTTP client for the live-stream endpoints on MDTPServer.
/// Uses plain URLSession — does NOT go through MDTPClient / Protobuf.
final class LiveStreamClient: @unchecked Sendable {

    // MARK: Types

    struct StartBody: Encodable {
        let stream_id: String
        let device_id: String
        let device_name: String
        let width: Int
        let height: Int
        let video_codec: String
        let audio_codec: String
        let started_at_ms: Int64
    }

    enum StreamError: LocalizedError {
        case httpError(statusCode: Int, context: String)
        case networkError(Error)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let context):
                return "HTTP \(code) en \(context)"
            case .networkError(let error):
                return "Red: \(error.localizedDescription)"
            case .invalidResponse:
                return "Respuesta inválida del servidor."
            }
        }

        var isRetryable: Bool {
            switch self {
            case .httpError(let code, _):
                return code >= 500
            case .networkError:
                return true
            case .invalidResponse:
                return false
            }
        }

        var statusCode: Int? {
            if case .httpError(let code, _) = self { return code }
            return nil
        }
    }

    // MARK: Properties

    private let baseURL: URL
    private let session: URLSession

    // MARK: Init

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - POST /v1/streams

    /// Start (or re-declare) a stream.  Returns the HTTP status code (201 or 200).
    @discardableResult
    func startStream(_ body: StartBody) async throws -> Int {
        let url = baseURL.appendingPathComponent("v1/streams")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request, context: "startStream")
    }

    // MARK: - POST /v1/streams/{id}/init

    func sendInit(streamID: String, deviceID: String, data: Data) async throws -> Int {
        let url = baseURL
            .appendingPathComponent("v1/streams")
            .appendingPathComponent(streamID)
            .appendingPathComponent("init")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(sha256Hex(data), forHTTPHeaderField: "X-Content-SHA256")
        request.httpBody = data

        return try await send(request, context: "sendInit")
    }

    // MARK: - POST /v1/streams/{id}/segments/{seq}

    func sendSegment(
        streamID: String,
        deviceID: String,
        seq: Int,
        data: Data,
        startMs: Int64,
        durationMs: Int,
        capturedAtMs: Int64? = nil
    ) async throws -> Int {
        let url = baseURL
            .appendingPathComponent("v1/streams")
            .appendingPathComponent(streamID)
            .appendingPathComponent("segments")
            .appendingPathComponent(String(seq))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(String(startMs), forHTTPHeaderField: "X-Segment-Start-Ms")
        request.setValue(String(durationMs), forHTTPHeaderField: "X-Segment-Duration-Ms")
        if let capturedAtMs {
            request.setValue(String(capturedAtMs), forHTTPHeaderField: "X-Captured-At-Ms")
        }
        request.setValue(sha256Hex(data), forHTTPHeaderField: "X-Content-SHA256")
        request.httpBody = data

        return try await send(request, context: "segment/\(seq)")
    }

    // MARK: - POST /v1/streams/{id}/stop

    func stopStream(streamID: String, deviceID: String) async throws -> Int {
        let url = baseURL
            .appendingPathComponent("v1/streams")
            .appendingPathComponent(streamID)
            .appendingPathComponent("stop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        request.httpBody = Data()  // empty body

        return try await send(request, context: "stopStream")
    }

    // MARK: - Helpers

    private func send(_ request: URLRequest, context: String) async throws -> Int {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StreamError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StreamError.invalidResponse
        }

        let code = http.statusCode
        switch code {
        case 200, 201, 204:
            return code
        default:
            throw StreamError.httpError(statusCode: code, context: context)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        let hash = MDTPSHA256.hash(data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

