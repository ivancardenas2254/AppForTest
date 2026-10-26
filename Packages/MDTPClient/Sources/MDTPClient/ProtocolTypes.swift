import Foundation

// Nombres cortos para los mensajes generados desde protocol_v1_completo.proto.
// Los tipos generados conservan el prefijo derivado del paquete `protocol.v1`.

/// Solicitud de registro de una instancia de dispositivo.
public typealias RegisterDeviceRequest = Protocol_V1_RegisterDeviceRequest

/// Respuesta con el identificador estable del dispositivo.
public typealias RegisterDeviceResponse = Protocol_V1_RegisterDeviceResponse

/// Solicitud para iniciar una transferencia de entrada.
public typealias TransferBeginRequest = Protocol_V1_TransferBeginRequest

/// Respuesta con el siguiente bloque esperado por el servidor.
public typealias TransferBeginResponse = Protocol_V1_TransferBeginResponse

/// Solicitud de envio de un bloque de subida.
public typealias TransferChunkRequest = Protocol_V1_TransferChunkRequest

/// Respuesta con el siguiente bloque esperado tras aceptar un bloque.
public typealias TransferChunkResponse = Protocol_V1_TransferChunkResponse

/// Solicitud de estado de una transferencia.
public typealias TransferStatusRequest = Protocol_V1_TransferStatusRequest

/// Estado actual de una transferencia.
public typealias TransferStatusResponse = Protocol_V1_TransferStatusResponse

/// Solicitud de confirmacion de una transferencia.
public typealias TransferCommitRequest = Protocol_V1_TransferCommitRequest

/// Resultado de la confirmacion de una transferencia.
public typealias TransferCommitResponse = Protocol_V1_TransferCommitResponse

/// Solicitud paginada del catalogo de dispositivos.
public typealias ListDevicesRequest = Protocol_V1_ListDevicesRequest

/// Pagina del catalogo de dispositivos.
public typealias ListDevicesResponse = Protocol_V1_ListDevicesResponse

/// Metadatos de un dispositivo detectado por el servidor.
public typealias DeviceInfo = Protocol_V1_DeviceInfo

/// Filtros y paginacion de una busqueda de registros.
public typealias SearchRecordsRequest = Protocol_V1_SearchRecordsRequest

/// Pagina de resultados de una busqueda.
public typealias SearchRecordsResponse = Protocol_V1_SearchRecordsResponse

/// Metadatos de un registro almacenado.
public typealias RecordInfo = Protocol_V1_RecordInfo

/// Solicitud de metadatos de un registro concreto.
public typealias GetRecordRequest = Protocol_V1_GetRecordRequest

/// Metadatos completos de un registro concreto.
public typealias GetRecordResponse = Protocol_V1_GetRecordResponse

/// Solicitud para iniciar una descarga.
public typealias DownloadBeginRequest = Protocol_V1_DownloadBeginRequest

/// Datos iniciales de una descarga.
public typealias DownloadBeginResponse = Protocol_V1_DownloadBeginResponse

/// Solicitud de un bloque de descarga.
public typealias DownloadChunkRequest = Protocol_V1_DownloadChunkRequest

/// Bloque de datos de una descarga.
public typealias DownloadChunkResponse = Protocol_V1_DownloadChunkResponse

/// Valores recomendados por el cliente.
public enum MDTPDefaults {
    /// Tamano de bloque recomendado: 1 MiB.
    public static let recommendedChunkSize: UInt32 = 1_048_576
}

/// Categorias sugeridas por el protocolo. El servidor puede devolver otras.
public enum MDTPDataCategory {
    /// Fotografias.
    public static let photo = "photo"
    /// Videos.
    public static let video = "video"
    /// Audio.
    public static let audio = "audio"
    /// Documentos.
    public static let document = "document"
    /// Contactos.
    public static let contact = "contact"
    /// Mensajes.
    public static let message = "message"
    /// Ubicaciones.
    public static let location = "location"
    /// Otras categorias.
    public static let other = "other"
}
