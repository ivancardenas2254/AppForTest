import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MDTPClient

private let transportEndpoint = URL(string: "https://example.test/v1/devices/list")!
private let transportBaseURL = URL(string: "https://example.test")!

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LockedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func store(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func load() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeHTTPResponse(
    status: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: transportEndpoint,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

@Suite("HTTPTransport", .serialized)
struct HTTPTransportTests {
    @Test("Respuesta 2xx y encabezados")
    func successfulResponse() async throws {
        defer { MockURLProtocol.handler = nil }

        let captured = LockedRequest()
        MockURLProtocol.handler = { request in
            captured.store(request)
            return (makeHTTPResponse(status: 200), Data([1, 2, 3]))
        }

        let configuration = MDTPConfiguration(
            baseURL: transportBaseURL,
            maximumResponseBytes: 1024,
            additionalHeaders: ["X-Prueba": "si"]
        )
        let transport = HTTPTransport(configuration: configuration, session: makeSession())
        let response = try await transport.send(Data([9, 9]), to: transportEndpoint)

        #expect(response.statusCode == 200)
        #expect(response.data == Data([1, 2, 3]))

        let request = try #require(captured.load())
        #expect(request.httpMethod == "POST")
        #expect(request.url == transportEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/x-protobuf")
        #expect(request.value(forHTTPHeaderField: "X-Prueba") == "si")
    }

    @Test("GET usa Accept JSON y los encabezados adicionales")
    func getRequest() async throws {
        defer { MockURLProtocol.handler = nil }

        let captured = LockedRequest()
        MockURLProtocol.handler = { request in
            captured.store(request)
            return (makeHTTPResponse(status: 200), Data(#"{"status":"ok"}"#.utf8))
        }

        let configuration = MDTPConfiguration(
            baseURL: transportBaseURL,
            additionalHeaders: ["X-Prueba": "si"]
        )
        let transport = HTTPTransport(configuration: configuration, session: makeSession())
        let response = try await transport.get(transportEndpoint, accept: "application/json")

        #expect(response.statusCode == 200)
        #expect(response.data == Data(#"{"status":"ok"}"#.utf8))

        let request = try #require(captured.load())
        #expect(request.httpMethod == "GET")
        #expect(request.url == transportEndpoint)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Prueba") == "si")
    }

    @Test("HTTP no exitoso conserva el estado")
    func httpStatus() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            (makeHTTPResponse(status: 503), Data("servicio no disponible".utf8))
        }

        let client = MDTPClient(
            configuration: MDTPConfiguration(baseURL: transportBaseURL),
            session: makeSession()
        )

        do {
            _ = try await client.listDevices()
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .httpStatus(503) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("Protobuf invalido en HTTP 200")
    func invalidProtobuf() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            (makeHTTPResponse(status: 200), Data([0xff, 0xff, 0xff]))
        }

        let client = MDTPClient(
            configuration: MDTPConfiguration(baseURL: transportBaseURL),
            session: makeSession()
        )

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

    @Test("Limite de respuesta por Content-Length")
    func responseTooLargeByHeader() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            (
                makeHTTPResponse(status: 200, headers: ["Content-Length": "64"]),
                Data(repeating: 0, count: 64)
            )
        }

        let configuration = MDTPConfiguration(
            baseURL: transportBaseURL,
            maximumResponseBytes: 32
        )
        let transport = HTTPTransport(configuration: configuration, session: makeSession())

        do {
            _ = try await transport.send(Data(), to: transportEndpoint)
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .responseTooLarge(let limit) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
            #expect(limit == 32)
        }
    }

    @Test("Limite de respuesta por tamano del cuerpo")
    func responseTooLargeByBody() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            (makeHTTPResponse(status: 200), Data(repeating: 0, count: 64))
        }

        let configuration = MDTPConfiguration(
            baseURL: transportBaseURL,
            maximumResponseBytes: 32
        )
        let transport = HTTPTransport(configuration: configuration, session: makeSession())

        do {
            _ = try await transport.send(Data(), to: transportEndpoint)
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .responseTooLarge(let limit) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
            #expect(limit == 32)
        }
    }

    @Test("Timeout de transporte")
    func timeout() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let configuration = MDTPConfiguration(baseURL: transportBaseURL)
        let transport = HTTPTransport(configuration: configuration, session: makeSession())

        do {
            _ = try await transport.send(Data(), to: transportEndpoint)
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .timeout = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
            #expect(error.isRetryable)
        }
    }

    @Test("Cancelacion de transporte")
    func cancellation() async throws {
        defer { MockURLProtocol.handler = nil }

        MockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        let configuration = MDTPConfiguration(baseURL: transportBaseURL)
        let transport = HTTPTransport(configuration: configuration, session: makeSession())

        do {
            _ = try await transport.send(Data(), to: transportEndpoint)
            Issue.record("Se esperaba un error")
        } catch is CancellationError {
            // Esperado.
        }
    }
}
