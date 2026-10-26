import Foundation

extension MDTPClient {
    // MARK: - Registro de dispositivo

    /// Registra un dispositivo con un identificador de instancia concreto.
    public func registerDevice(
        clientInstanceID: Data,
        deviceName: String = ""
    ) async throws -> RegisterDeviceResponse {
        var request = RegisterDeviceRequest()
        request.clientInstanceID = clientInstanceID
        request.deviceName = deviceName

        return try await send(
            request,
            to: MDTPEndpoint.registerDevice,
            expecting: RegisterDeviceResponse.self
        )
    }

    /// Genera un identificador de instancia nuevo y registra el dispositivo.
    public func registerDevice(deviceName: String = "") async throws -> RegisterDeviceResponse {
        try await registerDevice(
            clientInstanceID: Self.makeIdentifier(),
            deviceName: deviceName
        )
    }

    // MARK: - Transferencia de entrada

    /// Inicia una transferencia y devuelve el siguiente bloque que espera el
    /// servidor.
    public func transferBegin(
        deviceID: Data,
        transferID: Data,
        fileName: String,
        fileSize: UInt64,
        fileHash: Data,
        contentType: String = "",
        applicationID: String = "",
        dataCategory: String = "",
        sourceRecordID: String = ""
    ) async throws -> TransferBeginResponse {
        guard fileHash.count == 32 else {
            throw MDTPError.invalidHashLength(expected: 32, actual: fileHash.count)
        }

        var request = TransferBeginRequest()
        request.deviceID = deviceID
        request.transferID = transferID
        request.fileName = fileName
        request.fileSize = fileSize
        request.fileHash = fileHash
        request.contentType = contentType
        request.applicationID = applicationID
        request.dataCategory = dataCategory
        request.sourceRecordID = sourceRecordID

        return try await send(
            request,
            to: MDTPEndpoint.transferBegin,
            expecting: TransferBeginResponse.self
        )
    }

    /// Envia un bloque de subida.
    public func transferChunk(
        deviceID: Data,
        transferID: Data,
        chunkIndex: UInt32,
        chunkOffset: UInt64,
        chunkData: Data
    ) async throws -> TransferChunkResponse {
        var request = TransferChunkRequest()
        request.deviceID = deviceID
        request.transferID = transferID
        request.chunkIndex = chunkIndex
        request.chunkOffset = chunkOffset
        request.chunkData = chunkData

        return try await send(
            request,
            to: MDTPEndpoint.transferChunk,
            expecting: TransferChunkResponse.self
        )
    }

    /// Consulta el siguiente bloque y el estado de una transferencia.
    public func transferStatus(
        deviceID: Data,
        transferID: Data
    ) async throws -> TransferStatusResponse {
        var request = TransferStatusRequest()
        request.deviceID = deviceID
        request.transferID = transferID

        return try await send(
            request,
            to: MDTPEndpoint.transferStatus,
            expecting: TransferStatusResponse.self
        )
    }

    /// Confirma una transferencia. `upload` lanza un error si `success` es
    /// `false`.
    public func transferCommit(
        deviceID: Data,
        transferID: Data
    ) async throws -> TransferCommitResponse {
        var request = TransferCommitRequest()
        request.deviceID = deviceID
        request.transferID = transferID

        return try await send(
            request,
            to: MDTPEndpoint.transferCommit,
            expecting: TransferCommitResponse.self
        )
    }
}
