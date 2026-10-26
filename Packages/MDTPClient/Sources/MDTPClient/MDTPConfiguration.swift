import Foundation

/// Configuracion de red del cliente.
public struct MDTPConfiguration: Sendable {
    /// URL base del servidor; las rutas `/v1/...` se agregan a esta URL.
    public var baseURL: URL
    /// Tiempo maximo de cada solicitud.
    public var timeoutInterval: TimeInterval
    /// Limite de bytes aceptado en cada respuesta HTTP.
    public var maximumResponseBytes: Int
    /// Encabezados adicionales (por ejemplo, autorizacion del despliegue).
    public var additionalHeaders: [String: String]

    /// Crea una configuracion.
    ///
    /// - Parameters:
    ///   - baseURL: URL base del servidor.
    ///   - timeoutInterval: Tiempo maximo de cada solicitud, en segundos.
    ///   - maximumResponseBytes: Limite de bytes por respuesta.
    ///   - additionalHeaders: Encabezados HTTP adicionales.
    public init(
        baseURL: URL,
        timeoutInterval: TimeInterval = 60,
        maximumResponseBytes: Int = 2 * 1024 * 1024,
        additionalHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
        self.maximumResponseBytes = maximumResponseBytes
        self.additionalHeaders = additionalHeaders
    }
}
