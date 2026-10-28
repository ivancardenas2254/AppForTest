import AVFoundation
import Combine
import Foundation

@MainActor
final class APITestViewModel: ObservableObject {
    @Published private(set) var log: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var deviceID: String?
    @Published private(set) var records: [RemoteRecord] = []
    @Published private(set) var lastUpload: UploadSummary?
    @Published private(set) var isStreaming = false
    @Published private(set) var streamStats = CameraStreamStats()

    let baseURL: URL
    private let repository: MDTPRepository
    private let syncPhotosUseCase: SyncPhotosUseCase
    private let loadPhotosUseCase: LoadPhotosUseCase
    private let cameraStream: CameraStreamService

    init(
        repository: MDTPRepository,
        syncPhotosUseCase: SyncPhotosUseCase,
        loadPhotosUseCase: LoadPhotosUseCase,
        cameraStream: CameraStreamService? = nil
    ) {
        self.repository = repository
        self.syncPhotosUseCase = syncPhotosUseCase
        self.loadPhotosUseCase = loadPhotosUseCase
        self.baseURL = repository.baseURL
        self.deviceID = repository.storedDeviceID

        let stream = cameraStream ?? CameraStreamService(
            repository: repository,
            cameraAuthorization: AVCameraAuthorization()
        )
        self.cameraStream = stream
        stream.onLog = { [weak self] line in
            self?.append(line)
        }
        stream.onStateChange = { [weak self] streaming in
            self?.isStreaming = streaming
        }
        stream.onStats = { [weak self] stats in
            self?.streamStats = stats
        }

        if let prevCrash = CrashReporter.checkPreviousCrash() {
            append("⚠️ CRASH EN SESIÓN ANTERIOR:")
            for line in prevCrash.components(separatedBy: "\n") {
                append("  \(line)")
            }
        }
    }

    var streamPreviewSession: AVCaptureSession {
        cameraStream.captureSession
    }

    var streamStatusText: String {
        let state = isStreaming ? "Transmitiendo" : "Detenido"
        let megabytes = Double(streamStats.localBytes) / 1_000_000
        let totalSeconds = Int(streamStats.localDuration.rounded())
        let duration = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        let localMB = String(format: "%.1f", megabytes)
        return "\(state) · \(streamStats.recordedFragments) seg · "
            + "\(streamStats.uploadedFragments) enviados · "
            + "\(streamStats.pendingUploads) pendientes · "
            + "\(localMB) MB local · \(duration)"
    }

    var deviceLabel: String {
        deviceID ?? "sin registrar"
    }

    var recordsLabel: String {
        "\(records.count)"
    }

    func clearLog() {
        log.removeAll()
    }

    func checkConnection() async {
        await perform("Probar conexión (listDevices)") {
            let devices = try await repository.listDevices(pageSize: 1)
            append("Conexión OK · \(devices.count) dispositivo(s)")
        }
    }

    func checkHealth() async {
        await perform("Health GET /health") {
            let health = try await repository.health()
            append("status: \(health.status)\(health.isHealthy ? " · saludable" : " · no saludable")")
        }
    }

    func registerDevice() async {
        await perform("Registrar dispositivo") {
            let id = try await repository.registerDevice()
            deviceID = id
            append("deviceID: \(id)")
        }
    }

    func listDevices() async {
        await perform("Listar dispositivos") {
            let devices = try await repository.listDevices(pageSize: 50)
            if devices.isEmpty {
                append("Sin dispositivos.")
            } else {
                for device in devices {
                    let name = device.name.isEmpty ? "(sin nombre)" : device.name
                    append("\(name) · \(device.id) · \(device.platform) · \(device.recordCount) registros")
                }
            }
        }
    }

    func searchPhotos() async {
        await perform("Buscar fotos") {
            let result = try await repository.searchPhotos(pageSize: 50)
            records = result.records
            append("\(result.records.count) registro(s) · total \(result.totalCount)")
            for record in result.records.prefix(10) {
                append("\(record.fileName) · \(record.fileSize) bytes · \(record.id)")
            }
        }
    }

    func getFirstRecord() async {
        await perform("Obtener primer registro") {
            guard let record = records.first else {
                append("No hay registros. Buscá fotos primero.")
                return
            }
            let fetched = try await repository.getRecord(recordID: record.id)
            append("OK · \(fetched.fileName) · \(fetched.contentType)")
        }
    }

    func uploadLatestPhoto() async {
        await perform("Subir última foto") {
            let photos = try loadPhotosUseCase.execute()
            guard let photo = photos.first else {
                append("No hay fotos guardadas.")
                return
            }

            let id = try await repository.ensureDevice()
            let result = try await repository.upload(photo: photo, deviceID: id)
            deviceID = id
            lastUpload = result
            append("Subida OK · \(photo.fileName) · transferID \(result.transferID)")
        }
    }

    func syncPhotos() async {
        await perform("Sincronizar fotos") {
            let report = try await syncPhotosUseCase.execute()
            guard let id = report.deviceID else {
                append("No hay fotos guardadas.")
                return
            }

            deviceID = id
            records = report.records
            for failure in report.failures {
                append("✗ \(failure)")
            }
            append(
                "Sincronización: \(report.uploadedCount) subida(s), "
                + "\(report.skippedCount) existente(s), "
                + "\(report.failedCount) fallida(s) · "
                + "\(report.remoteRecordCount) en el servidor"
            )
        }
    }

    func transferStatus() async {
        await perform("Estado de última transferencia") {
            guard let upload = lastUpload else {
                append("No hay transferencia. Subí una foto primero.")
                return
            }
            let status = try await repository.transferStatus(
                deviceID: upload.deviceID,
                transferID: upload.transferID
            )
            append("nextChunkIndex: \(status.nextChunkIndex) · nextChunkOffset: \(status.nextChunkOffset)")
        }
    }

    func downloadFirstRecord() async {
        await perform("Descargar primer registro") {
            guard let record = records.first else {
                append("No hay registros. Buscá fotos primero.")
                return
            }
            let result = try await repository.download(record: record)
            append("Descarga OK · \(result.fileName) · \(result.fileSize) bytes")
        }
    }

    func startStreamCamera() async {
        guard !isStreaming else {
            append("El stream ya está activo.")
            return
        }

        append("→ Iniciar Stream HLS de Cámara")
        do {
            try await cameraStream.start()
        } catch {
            append("✗ \(error.localizedDescription)")
        }
    }

    func stopStreamCamera() async {
        guard isStreaming else {
            append("El stream no está activo.")
            return
        }

        append("→ Detener Stream de Cámara")
        await cameraStream.stop()
    }

    private func perform(_ title: String, operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        append("→ \(title)")
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            append("✗ \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }
}
