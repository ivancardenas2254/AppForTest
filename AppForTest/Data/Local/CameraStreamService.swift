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

// MARK: - FragmentedMP4Writer (Internal nonisolated pipeline)

private final class FragmentedMP4Writer: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    AVAssetWriterDelegate {

    private let queue: DispatchQueue
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isStarted = false
    private var firstPTS: CMTime?
    private var tempFileURL: URL?

    var onSegment: (@Sendable (Data, AVAssetSegmentType, AVAssetSegmentReport?) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    func start() {
        queue.async {
            self.setupWriter()
        }
    }

    private func setupWriter() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("livestream-\(UUID().uuidString).mp4")
        self.tempFileURL = tempURL

        do {
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
            writer.preferredOutputSegmentInterval = CMTime(seconds: 1.0, preferredTimescale: 1000)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.delegate = self

            // Video input: H.264, 640×480, ~1000 kbps, 1 keyframe/s
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 640,
                AVVideoHeightKey: 480,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                ] as [String: Any],
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            vInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
            if writer.canAdd(vInput) {
                writer.add(vInput)
                self.videoInput = vInput
            } else {
                self.onError?("AVAssetWriter no pudo agregar videoInput.")
            }

            // Audio input: AAC-LC, 1 channel, 44.1 kHz
            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.audioInput = aInput
            } else {
                self.onError?("AVAssetWriter no pudo agregar audioInput.")
            }

            self.assetWriter = writer
            self.isStarted = false
            self.firstPTS = nil
        } catch {
            self.onError?("No se pudo crear AVAssetWriter: \(error.localizedDescription)")
        }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.assetWriter else {
                    continuation.resume()
                    return
                }

                if writer.status == .writing {
                    writer.finishWriting {
                        if let url = self.tempFileURL {
                            try? FileManager.default.removeItem(at: url)
                        }
                        continuation.resume()
                    }
                } else {
                    if let url = self.tempFileURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    continuation.resume()
                }

                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.isStarted = false
            }
        }
    }

    // MARK: - Sample buffer delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let writer = assetWriter else { return }

        let isVideo = output is AVCaptureVideoDataOutput

        if !isStarted {
            guard isVideo else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, pts.isNumeric else { return }
            firstPTS = pts
            writer.initialSegmentStartTime = pts
            guard writer.startWriting() else {
                let msg = writer.error?.localizedDescription ?? "desconocido"
                onError?("AVAssetWriter.startWriting() falló: \(msg)")
                return
            }
            writer.startSession(atSourceTime: pts)
            isStarted = true
        }

        guard isStarted, writer.status == .writing else { return }

        let input = isVideo ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        onSegment?(segmentData, segmentType, segmentReport)
    }
}

// MARK: - CameraStreamService

@MainActor
final class CameraStreamService: NSObject {

    // MARK: - Local segment model

    private struct LocalSegment {
        let streamID: String
        let seq: Int
        let data: Data
        let startMs: Int64
        let durationMs: Int
        let capturedAtMs: Int64
        var uploaded: Bool
        var uploading: Bool
        let createdAt: Date
    }

    // MARK: - Dependencies

    private let repository: MDTPRepository
    private let cameraAuthorization: CameraAuthorization
    private let baseURL: URL

    // MARK: - Capture pipeline

    private nonisolated let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "AppForTest.CameraStream.session")
    private let writerQueue = DispatchQueue(label: "AppForTest.CameraStream.writer")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var writer: FragmentedMP4Writer?

    // MARK: - Streaming state

    private var isConfigured = false
    private var isStarting = false
    private(set) var isStreaming = false
    private var isStopping = false
    private var isInactive = false

    private var streamID: String = ""
    private var deviceID: String = ""
    private var deviceName: String = ""
    private var startedAtMs: Int64 = 0
    private var nextSeq: Int = 0
    private var nextSegmentStartMs: Int64 = 0
    private var lastSegmentStartMs: Int64 = -1

    // MARK: - Init segment

    private var initSegmentData: Data?
    private var initSent = false

    // MARK: - Local buffer (5 min window)

    private let maxLocalDuration: TimeInterval = 5 * 60
    private var segments: [LocalSegment] = []
    private var recordedSegments = 0
    private var uploadedSegments = 0

    // MARK: - Upload chain

    private var uploadChain: Task<Void, Never>?
    private var client: LiveStreamClient?

    // MARK: - Callbacks

    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onStats: ((CameraStreamStats) -> Void)?

    // MARK: - Init

    init(
        repository: MDTPRepository,
        cameraAuthorization: CameraAuthorization,
        baseURL: URL? = nil
    ) {
        self.repository = repository
        self.cameraAuthorization = cameraAuthorization
        self.baseURL = baseURL ?? repository.baseURL
        super.init()
        observeAppLifecycle()
    }

    var captureSession: AVCaptureSession { session }

    // MARK: - Start

    func start() async throws {
        guard !isStarting, !isStreaming, !isStopping else { return }

        isStarting = true
        defer { isStarting = false }

        // --- Camera permission ---
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

        // --- Microphone permission ---
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw CameraStreamError("Permiso de micrófono denegado. El stream requiere audio.")
            }
        case .denied, .restricted:
            throw CameraStreamError("Activa el acceso al micrófono en Ajustes. El stream requiere audio.")
        @unknown default:
            throw CameraStreamError("Estado de micrófono desconocido.")
        }

        // --- Configure session ---
        try await configureIfNeeded()

        // --- Device registration ---
        deviceID = try await repository.ensureDevice().lowercased()
        deviceName = String(UIDevice.current.name.prefix(60))

        // --- Generate stream_id (16 random bytes → 32 hex lowercase) ---
        streamID = Self.generateStreamID().lowercased()
        startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        nextSeq = 0
        nextSegmentStartMs = 0
        lastSegmentStartMs = -1
        initSegmentData = nil
        initSent = false
        segments.removeAll()
        recordedSegments = 0
        uploadedSegments = 0

        // --- HTTP client ---
        client = LiveStreamClient(baseURL: baseURL)

        // --- POST /v1/streams ---
        let startBody = LiveStreamClient.StartBody(
            stream_id: streamID,
            device_id: deviceID,
            device_name: deviceName,
            width: 640,
            height: 480,
            video_codec: "avc1.42E01E",
            audio_codec: "mp4a.40.2",
            started_at_ms: startedAtMs
        )

        let status = try await client!.startStream(startBody)
        onLog?("POST /v1/streams → \(status)")

        let playlistURL = "\(baseURL.absoluteString)/live/\(streamID)/live.m3u8"
        onLog?("stream_id: \(streamID.prefix(8))… · playlist: \(playlistURL)")
        onLog?("Reproducir con: ffplay -fflags nobuffer \(playlistURL)")

        // --- Start session & writer ---
        if UIApplication.shared.applicationState == .active {
            await startSession()
        } else {
            isInactive = true
        }

        isStreaming = true
        isStopping = false
        onStateChange?(true)
        publishStats()

        if isInactive {
            onLog?("La cámara esperará a que la app vuelva al primer plano.")
        } else {
            startWriter()
        }
    }

    // MARK: - Stop

    func stop() async {
        guard isStreaming, !isStopping else { return }

        isStopping = true
        isStreaming = false
        onStateChange?(false)

        // Finalize the writer (flushes the last segment)
        await finalizeWriter()

        // Wait for pending uploads to drain (best-effort, 3 s max)
        if let chain = uploadChain {
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            _ = await Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await chain.value }
                    group.addTask { await deadline.value }
                    await group.next()
                    group.cancelAll()
                }
            }.value
        }

        // POST /v1/streams/{id}/stop
        if let client {
            do {
                let status = try await client.stopStream(streamID: streamID, deviceID: deviceID)
                onLog?("POST /stop → \(status)")
            } catch {
                onLog?("POST /stop falló: \(error.localizedDescription)")
            }
        }

        await stopSession()
        isStopping = false
        onLog?("Stream detenido.")
    }

    // MARK: - Session configuration

    private func configureIfNeeded() async throws {
        guard !isConfigured else { return }

        let (vOut, aOut) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(AVCaptureVideoDataOutput, AVCaptureAudioDataOutput), Error>) in
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
                    // Audio session configuration for recording
                    let audioSession = AVAudioSession.sharedInstance()
                    try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
                    try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

                    // Session preset
                    let preset: AVCaptureSession.Preset = .vga640x480
                    self.session.sessionPreset = self.session.canSetSessionPreset(preset)
                        ? preset
                        : .medium

                    // Video input (back camera)
                    guard let videoDevice = AVCaptureDevice.default(
                        .builtInWideAngleCamera,
                        for: .video,
                        position: .back
                    ) ?? AVCaptureDevice.default(for: .video) else {
                        throw CameraStreamError("No se encontró una cámara disponible.")
                    }

                    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                    guard self.session.canAddInput(videoInput) else {
                        throw CameraStreamError("No se pudo agregar la cámara a la sesión.")
                    }
                    self.session.addInput(videoInput)

                    // Audio input (microphone)
                    guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                        throw CameraStreamError("No se encontró un micrófono disponible.")
                    }
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    guard self.session.canAddInput(audioInput) else {
                        throw CameraStreamError("No se pudo agregar el micrófono a la sesión.")
                    }
                    self.session.addInput(audioInput)

                    // Video data output
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    guard self.session.canAddOutput(videoOutput) else {
                        throw CameraStreamError("No se pudo configurar la salida de video.")
                    }
                    self.session.addOutput(videoOutput)

                    if let connection = videoOutput.connection(with: .video) {
                        connection.isEnabled = true
                    }

                    // Audio data output
                    let audioOutput = AVCaptureAudioDataOutput()
                    guard self.session.canAddOutput(audioOutput) else {
                        throw CameraStreamError("No se pudo configurar la salida de audio.")
                    }
                    self.session.addOutput(audioOutput)

                    succeeded = true
                    continuation.resume(returning: (videoOutput, audioOutput))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        self.videoOutput = vOut
        self.audioOutput = aOut
        self.isConfigured = true
    }

    private func startSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    if self.session.isRunning { break }
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

    // MARK: - Writer control

    private func startWriter() {
        let writer = FragmentedMP4Writer(queue: writerQueue)
        self.writer = writer

        writer.onSegment = { [weak self] segmentData, segmentType, segmentReport in
            Task { @MainActor [weak self] in
                self?.handleOutputSegment(segmentData, type: segmentType, report: segmentReport)
            }
        }

        writer.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.onLog?("✗ \(message)")
            }
        }

        videoOutput?.setSampleBufferDelegate(writer, queue: writerQueue)
        audioOutput?.setSampleBufferDelegate(writer, queue: writerQueue)

        writer.start()
    }

    private func finalizeWriter() async {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)

        if let writer = self.writer {
            await writer.finish()
            self.writer = nil
        }
    }

    private func handleOutputSegment(
        _ segmentData: Data,
        type segmentType: AVAssetSegmentType,
        report segmentReport: AVAssetSegmentReport?
    ) {
        switch segmentType {
        case .initialization:
            self.initSegmentData = segmentData
            self.onLog?("Init segment recibido · \(Self.formatBytes(UInt64(segmentData.count)))")
            self.enqueueInitUpload(segmentData, streamID: self.streamID)

        case .separable:
            guard self.isStreaming else { return }

            let seq = self.nextSeq
            self.nextSeq += 1

            // Compute timing relative to session start
            let durationMs: Int
            if let report = segmentReport,
               let trackReport = report.trackReports.first {
                let durSeconds = CMTimeGetSeconds(trackReport.duration)
                durationMs = (durSeconds.isFinite && durSeconds > 0)
                    ? max(1, Int((durSeconds * 1000).rounded()))
                    : 1000
            } else {
                durationMs = 1000
            }

            // Strictly monotonic startMs: startMs > lastSegmentStartMs
            let startMs = max(self.lastSegmentStartMs + 1, self.nextSegmentStartMs)
            self.lastSegmentStartMs = startMs
            self.nextSegmentStartMs = startMs + Int64(durationMs)

            let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

            let segment = LocalSegment(
                streamID: self.streamID,
                seq: seq,
                data: segmentData,
                startMs: startMs,
                durationMs: durationMs,
                capturedAtMs: capturedAtMs,
                uploaded: false,
                uploading: true,
                createdAt: Date()
            )

            self.segments.append(segment)
            self.recordedSegments += 1
            self.publishStats()
            self.enqueueSegmentUpload(seq: seq, streamID: self.streamID)
            self.pruneIfNeeded()

        @unknown default:
            break
        }
    }

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        let center = NotificationCenter.default

        _ = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidEnterBackground()
            }
        }

        _ = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWillEnterForeground()
            }
        }
    }

    private func handleDidEnterBackground() {
        guard !isInactive else { return }
        isInactive = true
        guard isStreaming else { return }

        onLog?(
            "App a background: captura pausada. "
            + "El stream se reanudará al volver."
        )

        Task { @MainActor in
            await self.finalizeWriter()
        }
    }

    private func handleWillEnterForeground() async {
        guard isInactive else { return }
        isInactive = false
        guard isStreaming else { return }

        onLog?("Cámara reanudada. Creando nuevo stream (PTS reinicia).")

        let oldStreamID = streamID
        let oldDeviceID = deviceID

        if let client {
            Task {
                try? await client.stopStream(streamID: oldStreamID, deviceID: oldDeviceID)
            }
        }

        // Generate new stream
        streamID = Self.generateStreamID().lowercased()
        startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        nextSeq = 0
        nextSegmentStartMs = 0
        lastSegmentStartMs = -1
        initSegmentData = nil
        initSent = false
        segments.removeAll()
        recordedSegments = 0
        uploadedSegments = 0

        // POST start for new stream
        if let client {
            let startBody = LiveStreamClient.StartBody(
                stream_id: streamID,
                device_id: deviceID,
                device_name: deviceName,
                width: 640,
                height: 480,
                video_codec: "avc1.42E01E",
                audio_codec: "mp4a.40.2",
                started_at_ms: startedAtMs
            )
            do {
                let status = try await client.startStream(startBody)
                onLog?("Nuevo stream → \(status) · \(streamID.prefix(8))…")
                let playlistURL = "\(baseURL.absoluteString)/live/\(streamID)/live.m3u8"
                onLog?("playlist: \(playlistURL)")
            } catch {
                onLog?("✗ No se pudo crear nuevo stream: \(error.localizedDescription)")
            }
        }

        publishStats()
        await startSession()
        startWriter()
    }

    // MARK: - Upload pipeline

    private func enqueueInitUpload(_ data: Data, streamID: String) {
        let previous = uploadChain
        uploadChain = Task { [weak self] in
            _ = await previous?.value
            await self?.doUploadInit(data, streamID: streamID)
        }
    }

    private func enqueueSegmentUpload(seq: Int, streamID: String) {
        let previous = uploadChain
        uploadChain = Task { [weak self] in
            _ = await previous?.value
            await self?.doUploadSegment(seq: seq, streamID: streamID)
        }
    }

    private func doUploadInit(_ data: Data, streamID: String) async {
        guard let client else { return }
        var attempt = 0
        let maxAttempts = 5
        var delay: UInt64 = 1_000_000_000  // 1 s

        while attempt < maxAttempts {
            attempt += 1
            do {
                let status = try await client.sendInit(
                    streamID: streamID,
                    deviceID: deviceID,
                    data: data
                )
                await MainActor.run {
                    self.initSent = true
                    self.onLog?("POST init → \(status) · \(Self.formatBytes(UInt64(data.count)))")
                }
                return
            } catch let error as LiveStreamClient.StreamError {
                if !error.isRetryable && error.statusCode != nil {
                    await MainActor.run {
                        self.onLog?("✗ init falló (no reintentable): \(error.localizedDescription)")
                    }
                    return
                }
                await MainActor.run {
                    self.onLog?("✗ init intento \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                }
            } catch {
                await MainActor.run {
                    self.onLog?("✗ init intento \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                }
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 8_000_000_000)
            }
        }
    }

    private func doUploadSegment(seq: Int, streamID: String) async {
        guard let client else { return }

        // Find segment data
        let segmentInfo: (data: Data, startMs: Int64, durationMs: Int, capturedAtMs: Int64)?
        segmentInfo = await MainActor.run { () -> (Data, Int64, Int, Int64)? in
            guard let s = self.segments.first(where: { $0.streamID == streamID && $0.seq == seq }) else { return nil }
            return (s.data, s.startMs, s.durationMs, s.capturedAtMs)
        }
        guard let info = segmentInfo else { return }

        var attempt = 0
        let maxAttempts = 5
        var delay: UInt64 = 1_000_000_000  // 1 s

        while attempt < maxAttempts {
            attempt += 1
            do {
                let status = try await client.sendSegment(
                    streamID: streamID,
                    deviceID: deviceID,
                    seq: seq,
                    data: info.data,
                    startMs: info.startMs,
                    durationMs: info.durationMs,
                    capturedAtMs: info.capturedAtMs
                )
                await MainActor.run {
                    if let idx = self.segments.firstIndex(where: { $0.streamID == streamID && $0.seq == seq }) {
                        self.segments[idx].uploaded = true
                        self.segments[idx].uploading = false
                    }
                    self.uploadedSegments += 1
                    self.onLog?(
                        "seg \(seq) → \(status) · \(Self.formatBytes(UInt64(info.data.count))) · "
                        + "start=\(info.startMs)ms dur=\(info.durationMs)ms"
                    )
                    self.pruneIfNeeded()
                    self.publishStats()
                }
                return
            } catch let error as LiveStreamClient.StreamError {
                // 409 = seq already passed or conflict → discard, move on
                if error.statusCode == 409 {
                    await MainActor.run {
                        self.onLog?("seg \(seq) → 409 (conflicto/vencido), descartado.")
                        if let idx = self.segments.firstIndex(where: { $0.streamID == streamID && $0.seq == seq }) {
                            self.segments[idx].uploading = false
                        }
                    }
                    return
                }
                if !error.isRetryable {
                    await MainActor.run {
                        self.onLog?("✗ seg \(seq) falló: \(error.localizedDescription)")
                        if let idx = self.segments.firstIndex(where: { $0.streamID == streamID && $0.seq == seq }) {
                            self.segments[idx].uploading = false
                        }
                    }
                    return
                }
                await MainActor.run {
                    self.onLog?("✗ seg \(seq) intento \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                }
            } catch {
                await MainActor.run {
                    self.onLog?("✗ seg \(seq) intento \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                }
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 8_000_000_000)
            }
        }

        // Exhausted retries
        await MainActor.run {
            if let idx = self.segments.firstIndex(where: { $0.streamID == streamID && $0.seq == seq }) {
                self.segments[idx].uploading = false
            }
            self.onLog?("✗ seg \(seq) agotó reintentos. Conservado en cola local.")
            self.publishStats()
        }
    }

    // MARK: - Buffer management

    private func pruneIfNeeded() {
        var totalDuration = segments.reduce(0.0) { $0 + Double($1.durationMs) / 1000.0 }
        while totalDuration > maxLocalDuration, let oldest = segments.first {
            guard oldest.uploaded else { break }
            segments.removeFirst()
            totalDuration -= Double(oldest.durationMs) / 1000.0
        }

        let cutoff = Date().addingTimeInterval(-maxLocalDuration)
        while let oldest = segments.first, oldest.createdAt < cutoff, !oldest.uploading {
            let dropped = segments.removeFirst()
            if !dropped.uploaded {
                onLog?("Descartado seg \(dropped.seq) (ventana 5 min excedida).")
            }
        }

        publishStats()
    }

    private func publishStats() {
        let pending = segments.filter { !$0.uploaded }.count
        let localDuration = segments.reduce(0.0) { $0 + Double($1.durationMs) / 1000.0 }
        let localBytes = segments.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        onStats?(
            CameraStreamStats(
                recordedFragments: recordedSegments,
                uploadedFragments: uploadedSegments,
                pendingUploads: pending,
                localDuration: localDuration,
                localBytes: localBytes
            )
        )
    }

    // MARK: - Helpers

    static func generateStreamID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
