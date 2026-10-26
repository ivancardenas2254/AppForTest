import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MDTPHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

protocol MDTPTransport: Sendable {
    func send(_ body: Data, to url: URL) async throws -> MDTPHTTPResponse
    func get(_ url: URL, accept: String) async throws -> MDTPHTTPResponse
}

struct HTTPTransport: MDTPTransport {
    private let configuration: MDTPConfiguration
    private let session: URLSession

    init(configuration: MDTPConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
            sessionConfiguration.timeoutIntervalForResource = configuration.timeoutInterval
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    func send(_ body: Data, to url: URL) async throws -> MDTPHTTPResponse {
        var request = makeRequest(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/x-protobuf",
                "Accept": "application/x-protobuf",
            ]
        )
        request.httpBody = body
        return try await perform(request)
    }

    func get(_ url: URL, accept: String) async throws -> MDTPHTTPResponse {
        let request = makeRequest(
            url: url,
            method: "GET",
            headers: ["Accept": accept]
        )
        return try await perform(request)
    }

    private func makeRequest(
        url: URL,
        method: String,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.timeoutInterval
        )
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> MDTPHTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw MDTPError.timeout
            case .cancelled:
                throw CancellationError()
            default:
                throw MDTPError.transport(error.localizedDescription)
            }
        } catch {
            throw MDTPError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MDTPError.invalidHTTPResponse
        }

        let limit = configuration.maximumResponseBytes
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(limit) {
            throw MDTPError.responseTooLarge(limit: limit)
        }
        guard data.count <= limit else {
            throw MDTPError.responseTooLarge(limit: limit)
        }

        return MDTPHTTPResponse(statusCode: http.statusCode, data: data)
    }
}
