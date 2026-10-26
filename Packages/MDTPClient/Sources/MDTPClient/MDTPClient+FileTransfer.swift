import Foundation

/// Progreso de una subida o descarga.
public struct MDTPTransferProgress: Sendable {
    /// Bytes transferidos hasta el momento.
    public let bytesTransferred: UInt64
    /// Tamano total conocido al iniciar.
    public let totalBytes: UInt64

    /// Crea un progreso con los bytes transferidos y el total conocido.
    public init(bytesTransferred: UInt64, totalBytes: UInt64) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }

    /// Fraccion completada entre 0 y 1; un total de cero se considera completo.
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

/// Resultado de una subida confirmada.
public struct MDTPUploadResult: Sendable {
    /// Dispositivo de destino.
    public let deviceID: Data
    /// Identificador de la transferencia.
    public let transferID: Data
    /// Confirmacion del servidor.
    public let success: Bool
}

/// Resultado de una descarga verificada.
public struct MDTPDownloadResult: Sendable {
    /// Registro descargado.
    public let recordID: Data
    /// Identificador de la descarga.
    public let downloadID: Data
    /// Tamano final del archivo.
    public let fileSize: UInt64
    /// SHA-256 calculado sobre el archivo descargado.
    public let sha256: Data
    /// Ruta local escrita.
    public let destination: URL
}

extension MDTPClient {
    /// Sube un archivo por bloques, reanudando desde el bloque indicado por
    /// `/v1/transfers` si el servidor ya tenia una transferencia en curso.
    public func upload(
        fileURL: URL,
        deviceID: Data,
        transferID: Data? = nil,
        fileName: String? = nil,
        contentType: String = "",
        applicationID: String = "",
        dataCategory: String = "",
        sourceRecordID: String = "",
        maxChunkSize: UInt32 = MDTPDefaults.recommendedChunkSize,
        progress: (@Sendable (MDTPTransferProgress) -> Void)? = nil
    ) async throws -> MDTPUploadResult {
        guard maxChunkSize > 0 else {
            throw MDTPError.invalidChunkSize(maxChunkSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw MDTPError.fileSystem("No se pudo obtener el tamano de \(fileURL.lastPathComponent).")
        }
        let fileSize = sizeNumber.uint64Value
        let fileHash = try MDTPSHA256.hash(fileAt: fileURL)
        let effectiveFileName = fileName ?? fileURL.lastPathComponent
        let effectiveTransferID = transferID ?? Self.makeIdentifier()

        let begin = try await transferBegin(
            deviceID: deviceID,
            transferID: effectiveTransferID,
            fileName: effectiveFileName,
            fileSize: fileSize,
            fileHash: fileHash,
            contentType: contentType,
            applicationID: applicationID,
            dataCategory: dataCategory,
            sourceRecordID: sourceRecordID
        )

        let chunkSize = begin.maxChunkSize == 0
            ? maxChunkSize
            : min(maxChunkSize, begin.maxChunkSize)
        guard chunkSize > 0 else {
            throw MDTPError.invalidChunkSize(chunkSize)
        }
        guard begin.nextChunkOffset <= fileSize else {
            throw MDTPError.invalidResponse("El servidor pidio un offset posterior al final del archivo.")
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var index = begin.nextChunkIndex
        var offset = begin.nextChunkOffset

        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: Int(chunkSize)), !data.isEmpty else {
                throw MDTPError.invalidResponse("El archivo termino antes del tamano declarado.")
            }
            guard index < UInt32.max else {
                throw MDTPError.invalidResponse("Se excedio el indice maximo de bloque.")
            }

            let response = try await transferChunk(
                deviceID: deviceID,
                transferID: effectiveTransferID,
                chunkIndex: index,
                chunkOffset: offset,
                chunkData: data
            )

            let expectedIndex = index + 1
            let expectedOffset = offset + UInt64(data.count)
            guard response.nextChunkIndex == expectedIndex else {
                throw MDTPError.invalidResponse(
                    "El servidor confirmo el bloque \(response.nextChunkIndex); se esperaba \(expectedIndex)."
                )
            }
            guard response.nextChunkOffset == expectedOffset else {
                throw MDTPError.invalidResponse(
                    "El servidor confirmo el offset \(response.nextChunkOffset); se esperaba \(expectedOffset)."
                )
            }

            index = response.nextChunkIndex
            offset = response.nextChunkOffset
            progress?(MDTPTransferProgress(bytesTransferred: min(offset, fileSize), totalBytes: fileSize))
        }

        guard offset == fileSize else {
            throw MDTPError.invalidResponse("La transferencia no llego al tamano declarado.")
        }

        let commit = try await transferCommit(
            deviceID: deviceID,
            transferID: effectiveTransferID
        )
        guard commit.success else {
            throw MDTPError.transferCommitFailed
        }

        return MDTPUploadResult(
            deviceID: deviceID,
            transferID: effectiveTransferID,
            success: commit.success
        )
    }

    /// Descarga un registro a partir de sus metadatos. Rechaza registros sin
    /// contenido disponible y valida el identificador y el SHA-256 anunciados.
    public func download(
        record: RecordInfo,
        to destinationURL: URL,
        maxChunkSize: UInt32 = MDTPDefaults.recommendedChunkSize,
        progress: (@Sendable (MDTPTransferProgress) -> Void)? = nil
    ) async throws -> MDTPDownloadResult {
        guard !record.recordID.isEmpty else {
            throw MDTPError.invalidResponse("El registro no tiene record_id.")
        }
        guard record.contentAvailable else {
            throw MDTPError.contentUnavailable
        }
        if !record.sha256.isEmpty, record.sha256.count != 32 {
            throw MDTPError.invalidHashLength(expected: 32, actual: record.sha256.count)
        }

        let result = try await download(
            recordID: record.recordID,
            to: destinationURL,
            maxChunkSize: maxChunkSize,
            progress: progress
        )
        if !record.sha256.isEmpty, result.sha256 != record.sha256 {
            throw MDTPError.hashMismatch(expected: record.sha256, actual: result.sha256)
        }
        return result
    }

    /// Descarga un registro por bloques y verifica el SHA-256 anunciado por el
    /// servidor. Si el archivo de destino ya existe con bytes previos, permite
    /// reanudar desde el offset devuelto por `/v1/downloads/begin`.
    public func download(
        recordID: Data,
        to destinationURL: URL,
        maxChunkSize: UInt32 = MDTPDefaults.recommendedChunkSize,
        progress: (@Sendable (MDTPTransferProgress) -> Void)? = nil
    ) async throws -> MDTPDownloadResult {
        guard maxChunkSize > 0 else {
            throw MDTPError.invalidChunkSize(maxChunkSize)
        }

        let begin = try await downloadBegin(recordID: recordID)
        let chunkSize = begin.maxChunkSize == 0
            ? maxChunkSize
            : min(maxChunkSize, begin.maxChunkSize)
        guard chunkSize > 0 else {
            throw MDTPError.invalidChunkSize(chunkSize)
        }

        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: destinationURL.path) {
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw MDTPError.fileSystem("No se pudo crear \(destinationURL.lastPathComponent).")
            }
        }

        let handle = try FileHandle(forUpdating: destinationURL)
        defer { try? handle.close() }

        let existingSize = try handle.seekToEnd()
        guard begin.nextChunkOffset <= existingSize else {
            throw MDTPError.invalidResponse("El servidor pidio reanudar mas alla del contenido local.")
        }

        var index = begin.nextChunkIndex
        var offset = begin.nextChunkOffset

        while offset < begin.fileSize {
            let remaining = begin.fileSize - offset
            let requestedLength = UInt32(min(UInt64(chunkSize), remaining))
            let chunk = try await downloadChunk(
                downloadID: begin.downloadID,
                chunkIndex: index,
                chunkOffset: offset,
                requestedLength: requestedLength
            )

            guard chunk.chunkIndex == index, chunk.chunkOffset == offset else {
                throw MDTPError.invalidChunk(
                    index: chunk.chunkIndex,
                    offset: chunk.chunkOffset,
                    expectedOffset: offset
                )
            }
            guard !chunk.chunkData.isEmpty else {
                throw MDTPError.invalidResponse("El servidor devolvio un bloque vacio antes del final.")
            }
            guard chunk.chunkData.count <= Int(requestedLength) else {
                throw MDTPError.invalidResponse("El servidor devolvio un bloque mayor que el solicitado.")
            }

            let (chunkEnd, overflow) = offset.addingReportingOverflow(UInt64(chunk.chunkData.count))
            guard !overflow, chunkEnd <= begin.fileSize else {
                throw MDTPError.invalidResponse("El servidor envio mas bytes que el tamano declarado.")
            }
            if chunk.isLastChunk, chunkEnd != begin.fileSize {
                throw MDTPError.invalidResponse("El servidor marco el ultimo bloque antes del final.")
            }

            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: chunk.chunkData)

            offset = chunkEnd
            index += 1
            progress?(MDTPTransferProgress(bytesTransferred: offset, totalBytes: begin.fileSize))

            if chunk.isLastChunk {
                break
            }
        }

        let finalSize = try handle.seekToEnd()
        guard finalSize >= begin.fileSize else {
            throw MDTPError.invalidResponse("La descarga termino antes del tamano declarado.")
        }
        if finalSize > begin.fileSize {
            try handle.truncate(atOffset: begin.fileSize)
        }
        try handle.synchronize()

        let actualHash = try MDTPSHA256.hash(fileAt: destinationURL)
        if !begin.sha256.isEmpty, actualHash != begin.sha256 {
            throw MDTPError.hashMismatch(expected: begin.sha256, actual: actualHash)
        }

        return MDTPDownloadResult(
            recordID: recordID,
            downloadID: begin.downloadID,
            fileSize: begin.fileSize,
            sha256: actualHash,
            destination: destinationURL
        )
    }
}
