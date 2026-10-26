import Foundation

/// Errores de transporte, validacion y protocolo producidos por el cliente.
public enum MDTPError: Error, Sendable, CustomStringConvertible {
    /// La respuesta no es HTTP valida.
    case invalidHTTPResponse
    /// El servidor respondio con un estado HTTP no exitoso.
    case httpStatus(Int)
    /// La respuesta supera `maximumResponseBytes`.
    case responseTooLarge(limit: Int)
    /// Vencio el tiempo de espera.
    case timeout
    /// Error de red u otro error de transporte.
    case transport(String)

    /// Un identificador obligatorio no mide 16 bytes.
    case invalidIdentifier(String)
    /// Un SHA-256 no mide 32 bytes.
    case invalidHashLength(expected: Int, actual: Int)
    /// La respuesta no tiene la estructura esperada.
    case invalidResponse(String)
    /// El registro no tiene contenido binario disponible.
    case contentUnavailable
    /// Un bloque no coincide con el indice u offset esperados.
    case invalidChunk(index: UInt32, offset: UInt64, expectedOffset: UInt64)
    /// El tamano de bloque no es valido.
    case invalidChunkSize(UInt32)
    /// El SHA-256 del contenido no coincide.
    case hashMismatch(expected: Data, actual: Data)
    /// El servidor no confirmo la transferencia.
    case transferCommitFailed
    /// Error al leer o escribir un archivo local.
    case fileSystem(String)

    /// Indica si tiene sentido reintentar la operacion.
    public var isRetryable: Bool {
        switch self {
        case .transport, .timeout:
            return true
        case .httpStatus(let status):
            return status >= 500
        default:
            return false
        }
    }

    /// Descripcion legible en espanol.
    public var description: String {
        switch self {
        case .invalidHTTPResponse:
            return "La respuesta no es HTTP valida."
        case .httpStatus(let status):
            return "El servidor respondio con HTTP \(status)."
        case .responseTooLarge(let limit):
            return "La respuesta supera el limite de \(limit) bytes."
        case .timeout:
            return "La solicitud excedio el tiempo de espera."
        case .transport(let message):
            return "Error de transporte: \(message)"
        case .invalidIdentifier(let name):
            return "El identificador \(name) debe contener exactamente 16 bytes."
        case .invalidHashLength(let expected, let actual):
            return "El SHA-256 debe contener \(expected) bytes; se recibieron \(actual)."
        case .invalidResponse(let message):
            return "Respuesta invalida: \(message)"
        case .contentUnavailable:
            return "El registro no tiene contenido binario disponible."
        case .invalidChunk(let index, let offset, let expectedOffset):
            return "Bloque \(index) en offset \(offset), se esperaba \(expectedOffset)."
        case .invalidChunkSize(let size):
            return "El tamano de bloque \(size) no es valido."
        case .hashMismatch:
            return "El SHA-256 del contenido no coincide."
        case .transferCommitFailed:
            return "El servidor no confirmo la transferencia."
        case .fileSystem(let message):
            return "Error de archivo: \(message)"
        }
    }
}
