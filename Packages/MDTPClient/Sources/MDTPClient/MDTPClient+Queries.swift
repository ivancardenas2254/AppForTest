import Foundation

extension MDTPClient {
    // MARK: - Dispositivos

    /// Obtiene una pagina del catalogo de dispositivos.
    public func listDevices(
        pageSize: UInt32 = 0,
        pageToken: String = ""
    ) async throws -> ListDevicesResponse {
        var request = ListDevicesRequest()
        request.pageSize = pageSize
        request.pageToken = pageToken

        return try await send(
            request,
            to: MDTPEndpoint.listDevices,
            expecting: ListDevicesResponse.self
        )
    }

    // MARK: - Registros

    /// Busca registros con filtros y paginacion.
    public func searchRecords(_ request: SearchRecordsRequest) async throws -> SearchRecordsResponse {
        try await send(
            request,
            to: MDTPEndpoint.searchRecords,
            expecting: SearchRecordsResponse.self
        )
    }

    /// Obtiene los metadatos de un registro concreto.
    ///
    /// Verifica que el servidor devuelva exactamente el registro solicitado.
    public func getRecord(recordID: Data) async throws -> GetRecordResponse {
        var request = GetRecordRequest()
        request.recordID = recordID

        let response: GetRecordResponse = try await send(
            request,
            to: MDTPEndpoint.getRecord,
            expecting: GetRecordResponse.self
        )

        guard response.record.recordID == recordID else {
            throw MDTPError.invalidResponse("GetRecordResponse devolvio un record_id distinto.")
        }
        return response
    }

    // MARK: - Descarga por bloques

    /// Inicia una descarga y valida el identificador, el SHA-256 y los limites
    /// anunciados.
    public func downloadBegin(recordID: Data) async throws -> DownloadBeginResponse {
        var request = DownloadBeginRequest()
        request.recordID = recordID

        let response: DownloadBeginResponse = try await send(
            request,
            to: MDTPEndpoint.downloadBegin,
            expecting: DownloadBeginResponse.self
        )

        guard !response.downloadID.isEmpty else {
            throw MDTPError.invalidResponse("DownloadBeginResponse contiene un download_id vacio.")
        }
        if !response.sha256.isEmpty, response.sha256.count != 32 {
            throw MDTPError.invalidHashLength(expected: 32, actual: response.sha256.count)
        }
        guard response.nextChunkOffset <= response.fileSize else {
            throw MDTPError.invalidResponse("El offset inicial de descarga supera el tamano del archivo.")
        }
        return response
    }

    /// Solicita un bloque de descarga. La longitud debe ser mayor que cero.
    public func downloadChunk(
        downloadID: Data,
        chunkIndex: UInt32,
        chunkOffset: UInt64,
        requestedLength: UInt32
    ) async throws -> DownloadChunkResponse {
        guard requestedLength > 0 else {
            throw MDTPError.invalidChunkSize(0)
        }

        var request = DownloadChunkRequest()
        request.downloadID = downloadID
        request.chunkIndex = chunkIndex
        request.chunkOffset = chunkOffset
        request.requestedLength = requestedLength

        return try await send(
            request,
            to: MDTPEndpoint.downloadChunk,
            expecting: DownloadChunkResponse.self
        )
    }
}
