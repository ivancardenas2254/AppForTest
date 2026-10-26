import Foundation

/// Respuesta JSON del endpoint `/health`.
public struct MDTPHealthResponse: Sendable, Equatable, Decodable {
    /// Estado reportado por el servidor, por ejemplo `ok`.
    public let status: String

    /// Crea una respuesta de salud.
    public init(status: String) {
        self.status = status
    }

    /// Indica si el servidor reporto `ok`, sin distinguir mayusculas.
    public var isHealthy: Bool {
        status.caseInsensitiveCompare("ok") == .orderedSame
    }
}

extension MDTPClient {
    /// Consulta `GET /health` y decodifica la respuesta JSON.
    ///
    /// Este endpoint no forma parte del contrato Protobuf: responde
    /// `{"status":"ok"}` con `Content-Type: application/json`.
    public func health() async throws -> MDTPHealthResponse {
        let url = configuration.baseURL.appendingPathComponent(MDTPEndpoint.health)
        let response = try await transport.get(url, accept: "application/json")
        guard (200..<300).contains(response.statusCode) else {
            throw MDTPError.httpStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(MDTPHealthResponse.self, from: response.data)
        } catch {
            throw MDTPError.invalidResponse(error.localizedDescription)
        }
    }
}
