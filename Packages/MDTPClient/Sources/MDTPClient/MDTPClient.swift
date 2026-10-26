import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftProtobuf

/// Cliente del protocolo MDTP v1.
///
/// Cada operacion se envia como un mensaje Protobuf a una ruta HTTP concreta.
/// El endpoint determina el tipo de solicitud y de respuesta.
public final class MDTPClient: Sendable {
    /// Configuracion usada por este cliente.
    public let configuration: MDTPConfiguration

    let transport: any MDTPTransport

    /// Crea un cliente con una `URLSession` efimera.
    public convenience init(configuration: MDTPConfiguration) {
        self.init(
            configuration: configuration,
            transport: HTTPTransport(configuration: configuration)
        )
    }

    /// Permite usar una `URLSession` propia, por ejemplo para TLS pinning,
    /// proxies o pruebas de integracion.
    public convenience init(configuration: MDTPConfiguration, session: URLSession) {
        self.init(
            configuration: configuration,
            transport: HTTPTransport(configuration: configuration, session: session)
        )
    }

    init(configuration: MDTPConfiguration, transport: any MDTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// UUID binario RFC 4122 de 16 bytes.
    public static func makeIdentifier() -> Data {
        var uuid = UUID().uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }

    /// Serializa la solicitud, la envia a `path` y decodifica la respuesta.
    ///
    /// Cualquier estado HTTP fuera de 2xx se informa como `MDTPError.httpStatus`.
    func send<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        _ request: Request,
        to path: String,
        expecting responseType: Response.Type
    ) async throws -> Response {
        let requestBytes = try request.serializedData()
        let httpResponse = try await transport.send(requestBytes, to: endpointURL(for: path))
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MDTPError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try Response(serializedBytes: httpResponse.data)
        } catch {
            throw MDTPError.invalidResponse(error.localizedDescription)
        }
    }

    private func endpointURL(for path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }
}

enum MDTPEndpoint {
    static let health = "health"
    static let registerDevice = "v1/devices/register"
    static let transferBegin = "v1/transfers"
    static let transferChunk = "v1/transfers/chunk"
    static let transferStatus = "v1/transfers/status"
    static let transferCommit = "v1/transfers/commit"
    static let listDevices = "v1/devices/list"
    static let searchRecords = "v1/records/search"
    static let getRecord = "v1/records/get"
    static let downloadBegin = "v1/downloads/begin"
    static let downloadChunk = "v1/downloads/chunk"
}
