import Foundation
import Testing
@testable import MDTPClient

@Suite("Health")
struct HealthTests {
    @Test("health consulta /health y decodifica el estado")
    func health() async throws {
        let log = RequestLog()
        let client = MDTPClient(
            configuration: MDTPConfiguration(baseURL: baseURL),
            transport: MockTransport(
                handler: { _, _ in
                    Issue.record("health no debe usar POST")
                    return MDTPHTTPResponse(statusCode: 500, data: Data())
                },
                getHandler: { url, accept in
                    await log.append(url)
                    #expect(accept == "application/json")
                    #expect(url.path == "/health")
                    return MDTPHTTPResponse(
                        statusCode: 200,
                        data: Data(#"{"status":"ok"}"#.utf8)
                    )
                }
            )
        )

        let response = try await client.health()

        #expect(response.status == "ok")
        #expect(response.isHealthy)
        #expect(await log.paths == ["/health"])
    }

    @Test("health informa un estado HTTP no exitoso")
    func healthHTTPError() async throws {
        let client = MDTPClient(
            configuration: MDTPConfiguration(baseURL: baseURL),
            transport: MockTransport(
                handler: { _, _ in
                    Issue.record("health no debe usar POST")
                    return MDTPHTTPResponse(statusCode: 500, data: Data())
                },
                getHandler: { _, _ in
                    MDTPHTTPResponse(statusCode: 503, data: Data())
                }
            )
        )

        do {
            _ = try await client.health()
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .httpStatus(503) = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }

    @Test("health rechaza una respuesta JSON invalida")
    func healthInvalidJSON() async throws {
        let client = MDTPClient(
            configuration: MDTPConfiguration(baseURL: baseURL),
            transport: MockTransport(
                handler: { _, _ in
                    Issue.record("health no debe usar POST")
                    return MDTPHTTPResponse(statusCode: 500, data: Data())
                },
                getHandler: { _, _ in
                    MDTPHTTPResponse(statusCode: 200, data: Data("no-json".utf8))
                }
            )
        )

        do {
            _ = try await client.health()
            Issue.record("Se esperaba un error")
        } catch let error as MDTPError {
            guard case .invalidResponse = error else {
                Issue.record("Error inesperado: \(error)")
                return
            }
        }
    }
}
