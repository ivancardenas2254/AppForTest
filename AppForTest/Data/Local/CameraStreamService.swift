import AVFoundation
import Foundation
import UIKit

struct CameraStreamError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@MainActor
final class CameraStreamService: NSObject {
    private struct LocalFragment {
        let id: UUID
        let url: URL
        let duration: TimeInterval
        let sizeBytes: UInt64
        var uploaded: Bool
        var uploading: Bool
    }

    private let repository: MDTPRepository
    private let cameraAuthorization: CameraAuthorization
    private let fileManager: FileManager

    private nonisolated let session = AVCaptureSession()
    private nonisolated let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "AppForTest.CameraStream.session")

    private nonisolated let maxFragmentBytes: Int64
    private nonisolated let maxFragmentDuration: TimeInterval
    private let maxLocalDuration: TimeInterval
    private let contentType = "video/quicktime"

    private var isConfigured = false
    private var isStarting = false
    private var isStreaming = false
    private var isStopping = false
    private var isInactive = false
    private var isPausingForSystem = false
    private var currentFragmentURL: URL?
    private var currentFragmentStartedAt: Date?
    private var deviceID: String?

    private var fragments: [LocalFragment] = []
    private var recordedFragments = 0
    private var uploadedFragments = 0
    private var recordingStartFailures = 0
    private var didLoadExistingFragments = false

    private var uploadChain: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onStats: ((CameraStreamStats) -> Void)?

    init(
        repository: MDTPRepository,
        cameraAuthorization: CameraAuthorization,
        fileManager: FileManager = .default,
        maxFragmentBytes: Int64 = 1_000_000,
        maxFragmentDuration: TimeInterval = 60,
        maxLocalDuration: TimeInterval = 5 * 60
    ) {
        self.repository = repository
        self.cameraAuthorization = cameraAuthorization
        self.fileManager = fileManager
        self.maxFragmentBytes = maxFragmentBytes
        self.maxFragmentDuration = maxFragmentDuration
        self.maxLocalDuration = maxLocalDuration
        super.init()
        observeAppLifecycle()
    }

    var captureSession: AVCaptureSession { session }

    func start() async throws {
        guard !isStarting, !isStreaming, !isStopping else { return }

        isStarting = true
        defer { isStarting = false }

        switch cameraAuthorization.status() {
        case .authorized:
            break
        case .notDetermined:
            guard await cameraAuthorization.requestAccess() else {
                throw CameraStreamError("Permiso de cámara denegado.")
            }
        case .denied:
            throw CameraStreamError("Activa el acceso a la cámara en Ajustes para transmitir.")
        }

        guard cameraAuthorization.isCameraAvailable else {
            throw CameraStreamError("La cámara no está disponible en este dispositivo.")
        }

        try await configureIfNeeded()
        try ensureStreamDirectory()

        deviceID = try await repository.ensureDevice()

        if !didLoadExistingFragments {
            didLoadExistingFragments = true
            await loadExistingFragments()
        } else {
            retryPendingUploads()
        }

        if UIApplication.shared.applicationState == .active {
            await startSession()
        } else {
            isInactive = true
        }

        isStreaming = true
        isStopping = false
        recordingStartFailures = 0
        onStateChange?(true)
        publishStats()
        onLog?(
            "Stream iniciado · fragmentos de hasta "
            + "\(maxFragmentBytes / 1_000_000) MB · ventana local de 5 min"
        )

        if isInactive {
            onLog?("La cámara esperará a que la app vuelva al primer plano.")
        } else {
            startNextFragment()
        }
    }

    func stop() async {
        guard isStreaming, !isStopping else { return }

        isStopping = true
        isStreaming = false
        onStateChange?(false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopContinuation = continuation
            sessionQueue.async {
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                } else {
                    Task { @MainActor in
                        self.resumeStopIfNeeded()
                    }
                }
            }
        }

        await stopSession()
        isStopping = false
        isPausingForSystem = false
        onLog?("Stream detenido. Los fragmentos pendientes continúan enviándose.")
    }

    private var streamDirectoryURL: URL {
        fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraStream", isDirectory: true)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func ensureStreamDirectory() throws {
        try fileManager.createDirectory(
            at: streamDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func configureIfNeeded() async throws {
        guard !isConfigured else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                self.session.beginConfiguration()
                var succeeded = false
                defer {
                    if !succeeded {
                        self.session.inputs.forEach { self.session.removeInput($0) }
                        self.session.outputs.forEach { self.session.removeOutput($0) }
                    }
                    self.session.commitConfiguration()
                }

                do {
                    self.session.sessionPreset = .high

                    guard let device = AVCaptureDevice.default(
                        .builtInWideAngleCamera,
                        for: .video,
                        position: .back
                    ) ?? AVCaptureDevice.default(for: .video) else {
                        throw CameraStreamError("No se encontró una cámara disponible.")
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else {
                        throw CameraStreamError("No se pudo agregar la cámara a la sesión.")
                    }
                    self.session.addInput(input)

                    guard self.session.canAddOutput(self.movieOutput) else {
                        throw CameraStreamError("No se pudo configurar la grabación de video.")
                    }
                    self.session.addOutput(self.movieOutput)

                    self.movieOutput.maxRecordedFileSize = self.maxFragmentBytes
                    self.movieOutput.maxRecordedDuration = CMTime(
                        seconds: self.maxFragmentDuration,
                        preferredTimescale: 600
                    )
                    self.movieOutput.minFreeDiskSpaceLimit = 10 * 1024 * 1024

                    if let connection = self.movieOutput.connection(with: .video) {
                        connection.isEnabled = true
                        if connection.isVideoOrientationSupported {
                            connection.videoOrientation = .portrait
                        }
                    }

                    succeeded = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        isConfigured = true
    }

    private func startSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }

                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    let connection = self.movieOutput.connection(with: .video)
                    if self.session.isRunning, connection?.isActive == true {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume()
            }
        }
    }

    private func stopSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    private func startNextFragment() {
        guard isStreaming, !isStopping, !isInactive else { return }
        guard currentFragmentURL == nil else { return }

        guard UIApplication.shared.applicationState == .active else {
            isInactive = true
            return
        }

        let name = "STREAM-\(Self.fileNameFormatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).mov"
        let url = streamDirectoryURL.appendingPathComponent(name)

        currentFragmentURL = url
        currentFragmentStartedAt = Date()

        sessionQueue.async {
            let isReady = self.session.isRunning
                && self.movieOutput.connection(with: .video)?.isActive == true
            if !isReady {
                Task { @MainActor in
                    self.onLog?("La cámara no está lista todavía; se intentará grabar igualmente.")
                }
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func handleFragmentFinished(url: URL, error: Error?) async {
        let startedAt = currentFragmentStartedAt
        currentFragmentURL = nil
        currentFragmentStartedAt = nil

        let wasStopping = isStopping
        let wasPausingForSystem = isPausingForSystem
        isPausingForSystem = false
        let expectedLimit = isExpectedLimit(error)
        let size = fileSize(of: url)
        let succeeded = size > 0 && (error == nil || expectedLimit || recordingSucceeded(error))

        if succeeded {
            recordingStartFailures = 0
            var duration = await duration(of: url)
            if duration <= 0, let startedAt {
                duration = max(0, Date().timeIntervalSince(startedAt))
            }

            let fragment = LocalFragment(
                id: UUID(),
                url: url,
                duration: duration,
                sizeBytes: size,
                uploaded: false,
                uploading: false
            )
            fragments.append(fragment)
            recordedFragments += 1
            onLog?(
                "Fragmento \(url.lastPathComponent) · "
                + "\(Self.formatBytes(size)) · \(Self.formatDuration(duration))"
            )
            publishStats()
            enqueueUpload(id: fragment.id)
            pruneIfNeeded()
        } else {
            try? fileManager.removeItem(at: url)
            if let error, !expectedLimit {
                let nsError = error as NSError
                onLog?(
                    "✗ La grabación se detuvo "
                    + "[\(nsError.domain) \(nsError.code)]: \(error.localizedDescription)"
                )
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    onLog?(
                        "  Causa: [\(underlying.domain) \(underlying.code)] "
                        + "\(underlying.localizedDescription)"
                    )
                }
            } else if size == 0 {
                onLog?("✗ La grabación no generó datos.")
            }
        }

        if wasStopping {
            resumeStopIfNeeded()
            return
        }

        if isInactive {
            return
        }

        guard isStreaming else { return }

        if succeeded || wasPausingForSystem {
            recordingStartFailures = 0
            startNextFragment()
            return
        }

        guard UIApplication.shared.applicationState == .active else { return }

        if size == 0 {
            recordingStartFailures += 1
            if recordingStartFailures <= 2 {
                onLog?(
                    "Reintentando iniciar la grabación "
                    + "(\(recordingStartFailures)/2)..."
                )
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self,
                          self.isStreaming,
                          !self.isStopping,
                          !self.isInactive else {
                        return
                    }
                    self.startNextFragment()
                }
                return
            }
        }

        recordingStartFailures = 0
        isStreaming = false
        onStateChange?(false)
        onLog?("Stream detenido por un error de grabación.")
        await stopSession()
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default

        _ = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillResignActive()
            }
        }

        _ = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleDidBecomeActive()
            }
        }
    }

    private func handleWillResignActive() {
        guard !isInactive else { return }
        isInactive = true
        guard isStreaming else { return }

        isPausingForSystem = true
        onLog?(
            "La app perdió el foco o pasó a segundo plano: iOS pausa la cámara. "
            + "El stream se reanudará al volver."
        )

        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    private func handleDidBecomeActive() async {
        guard isInactive else { return }
        isInactive = false
        guard isStreaming else {
            isPausingForSystem = false
            return
        }

        await startSession()
        if currentFragmentURL == nil {
            isPausingForSystem = false
            startNextFragment()
        }
        onLog?("Cámara reanudada.")
    }

    private func resumeStopIfNeeded() {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil
        continuation.resume()
    }

    private func retryPendingUploads() {
        for fragment in fragments where !fragment.uploaded && !fragment.uploading {
            enqueueUpload(id: fragment.id)
        }
    }

    private func enqueueUpload(id: UUID) {
        guard let index = fragments.firstIndex(where: { $0.id == id }),
              !fragments[index].uploaded,
              !fragments[index].uploading else {
            return
        }

        fragments[index].uploading = true
        let previous = uploadChain
        uploadChain = Task { [weak self] in
            _ = await previous?.value
            await self?.uploadFragment(id: id)
        }
    }

    private func uploadFragment(id: UUID) async {
        guard let fragment = fragments.first(where: { $0.id == id }) else { return }

        let deviceID: String
        do {
            deviceID = try await ensureDeviceID()
        } catch {
            markUploadFinished(id: id)
            onLog?("✗  No se pudo registrar el dispositivo: \(error.localizedDescription)")
            return
        }

        let fileName = fragment.url.lastPathComponent
        var attempt = 1

        while attempt <= 3 {
            do {
                let summary = try await repository.uploadVideo(
                    fileURL: fragment.url,
                    deviceID: deviceID,
                    fileName: fileName,
                    contentType: contentType
                )

                try? Data().write(to: uploadedMarkerURL(for: fragment.url))
                if let index = fragments.firstIndex(where: { $0.id == id }) {
                    fragments[index].uploaded = true
                    fragments[index].uploading = false
                }
                uploadedFragments += 1
                onLog?(
                    "Enviado \(fileName) · \(Self.formatBytes(fragment.sizeBytes)) · "
                    + "transfer \(summary.transferID.prefix(8))..."
                )
                pruneIfNeeded()
                publishStats()
                return
            } catch {
                if attempt == 3 {
                    markUploadFinished(id: id)
                    let message = error.localizedDescription
                    onLog?(
                        "✗  No se pudo enviar \(fileName) tras 3 intentos: "
                        + "\(message). Se conserva localmente."
                    )
                    publishStats()

                    if (try? await repository.health()) == nil {
                        await stopForServerLoss(message)
                    }
                    return
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func markUploadFinished(id: UUID) {
        guard let index = fragments.firstIndex(where: { $0.id == id }) else { return }
        fragments[index].uploading = false
    }

    private func stopForServerLoss(_ message: String) async {
        guard isStreaming else { return }
        onLog?("Sin acceso al servidor: \(message). Deteniendo stream.")
        await stop()
    }

    private func ensureDeviceID() async throws -> String {
        if let deviceID { return deviceID }
        let id = try await repository.ensureDevice()
        deviceID = id
        return id
    }

    private func pruneIfNeeded() {
        var totalDuration = fragments.reduce(0) { $0 + $1.duration }

        while totalDuration > maxLocalDuration, let oldest = fragments.first {
            guard oldest.uploaded else { break }

            try? fileManager.removeItem(at: oldest.url)
            try? fileManager.removeItem(at: uploadedMarkerURL(for: oldest.url))
            fragments.removeFirst()
            totalDuration -= oldest.duration
            onLog?(
                "Eliminado localmente \(oldest.url.lastPathComponent) "
                + "(ventana de 5 minutos)."
            )
        }

        publishStats()
    }

    private func publishStats() {
        onStats?(
            CameraStreamStats(
                recordedFragments: recordedFragments,
                uploadedFragments: uploadedFragments,
                pendingUploads: fragments.filter { !$0.uploaded }.count,
                localDuration: fragments.reduce(0) { $0 + $1.duration },
                localBytes: fragments.reduce(0) { $0 + $1.sizeBytes }
            )
        )
    }

    private func loadExistingFragments() async {
        let urls = (try? fileManager.contentsOfDirectory(
            at: streamDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let videos = urls
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left < right
            }

        guard !videos.isEmpty else { return }

        onLog?("Recuperando \(videos.count) fragmento(s) de sesiones anteriores.")

        for url in videos {
            let size = fileSize(of: url)
            guard size > 0 else {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: uploadedMarkerURL(for: url))
                continue
            }

            let duration = await duration(of: url)
            guard duration > 0 else {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: uploadedMarkerURL(for: url))
                onLog?("Descartado fragmento incompleto: \(url.lastPathComponent)")
                continue
            }

            let uploaded = fileManager.fileExists(atPath: uploadedMarkerURL(for: url).path)
            let fragment = LocalFragment(
                id: UUID(),
                url: url,
                duration: duration,
                sizeBytes: size,
                uploaded: uploaded,
                uploading: false
            )
            fragments.append(fragment)
            recordedFragments += 1
            if uploaded {
                uploadedFragments += 1
            } else {
                enqueueUpload(id: fragment.id)
            }
        }

        pruneIfNeeded()
        publishStats()
    }

    private func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func fileSize(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func uploadedMarkerURL(for url: URL) -> URL {
        url.appendingPathExtension("uploaded")
    }

    private func isExpectedLimit(_ error: Error?) -> Bool {
        guard let error = error as? AVError else { return false }
        switch error.code {
        case .maximumFileSizeReached, .maximumDurationReached:
            return true
        default:
            return false
        }
    }

    private func recordingSucceeded(_ error: Error?) -> Bool {
        guard let error else { return true }
        let nsError = error as NSError
        let value = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber
        return value?.boolValue ?? false
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension CameraStreamService: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            await self?.handleFragmentFinished(url: outputFileURL, error: error)
        }
    }
}

