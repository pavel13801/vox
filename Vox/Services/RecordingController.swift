import Foundation
import AVFoundation
import Combine
import UIKit

/// Orchestrates a recording session: audio source → pipeline (file + Deepgram) → conversation in the store.
/// Supports continuous recording with automatic splitting into separate conversations after silence.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum LiveStatus: Equatable {
        case off
        case connecting
        case live
        case reconnecting
        case failed(String)

        var label: String {
            switch self {
            case .off: return "Расшифровка после записи"
            case .connecting: return "Подключение к Deepgram…"
            case .live: return "Live-расшифровка"
            case .reconnecting: return "Нет связи — пишу в буфер"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var source: AudioSourceKind = .phone
    @Published private(set) var conversationID: UUID?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var liveStatus: LiveStatus = .off
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var interim = ""
    @Published private(set) var isInterrupted = false
    @Published private(set) var waitingForDevice = false
    @Published private(set) var conversationsThisSession = 0
    @Published var lastError: String?

    private final class Session {
        let id: UUID
        let pipeline: AudioPipeline
        let startedAt: Date
        var transcript = LiveTranscript()
        var lastSpeechAt = Date()
        var hasSpeech = false
        var seconds: Double = 0
        var lastPersist = Date()
        var liveEverOpened = false
        var liveFailed = false

        init(id: UUID, pipeline: AudioPipeline, startedAt: Date) {
            self.id = id
            self.pipeline = pipeline
            self.startedAt = startedAt
        }
    }

    private var session: Session?
    private var finishing: [UUID: Session] = [:]
    private var mic: PhoneMicSource?
    private let keepAlive = SilentKeepAlive()
    private let box = PipelineBox()
    private var timer: Timer?
    private var deviceLostAt: Date?
    private var bootstrapped = false

    private var settings: AppSettings { AppSettings.shared }
    private var store: AppStore { AppStore.shared }

    // MARK: Setup

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let device = OmiDeviceManager.shared
        device.onReadyChange = { ready in
            Task { @MainActor in RecordingController.shared.deviceReadyChanged(ready) }
        }
        if device.hasSavedDevice { device.activate() }
    }

    private func deviceReadyChanged(_ ready: Bool) {
        let device = OmiDeviceManager.shared
        if ready {
            deviceLostAt = nil
            if isRecording && source == .omi {
                if session == nil {
                    beginSession()
                } else if let s = session, s.pipeline.sampleRate != device.currentSampleRate {
                    rotate()
                }
                waitingForDevice = false
            } else if !isRecording && settings.omiAutoRecord {
                Task { await start(source: .omi) }
            }
        } else if isRecording && source == .omi {
            deviceLostAt = Date()
        }
    }

    // MARK: Public controls

    func start(source: AudioSourceKind) async {
        guard !isRecording else { return }
        lastError = nil
        if source == .phone {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                lastError = "Нет доступа к микрофону. Разрешите его в Настройках iOS → Vox."
                return
            }
        }
        if settings.transcriptionMode == .live && !settings.hasKey("deepgram") {
            let bp = settings.batchProvider
            if bp != "deepgram" && settings.hasKey(bp) && settings.sttEngine(bp) != nil {
                lastError = "Live-текст работает только с Deepgram. Запись расшифруется после остановки через \(settings.title(bp))."
            } else {
                lastError = "Ключ Deepgram не задан — запись сохранится, расшифруйте её позже (Настройки → Расшифровка файла)."
            }
        }

        self.source = source
        isRecording = true
        RecordingActivity.isActive = true
        conversationsThisSession = 0

        switch source {
        case .phone:
            let mic = PhoneMicSource()
            let box = self.box
            mic.onPCM = { data in box.ingest(data) }
            mic.onInterruption = { began in
                Task { @MainActor in RecordingController.shared.isInterrupted = began }
            }
            self.mic = mic
            beginSession()
            do {
                try mic.start()
            } catch {
                lastError = "Не удалось включить микрофон: \(error.localizedDescription)"
                await stop()
                return
            }
        case .omi:
            let device = OmiDeviceManager.shared
            let box = self.box
            device.onPCM = { data in box.ingest(data) }
            if settings.backgroundKeepAlive { keepAlive.start() }
            if device.isReady {
                beginSession()
            } else {
                waitingForDevice = true
                device.reconnectSaved()
            }
        case .imported:
            isRecording = false
            RecordingActivity.isActive = false
            return
        }
        startTimer()
    }

    func stop() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        mic = nil
        if source == .omi { OmiDeviceManager.shared.onPCM = nil }
        keepAlive.stop()
        finalizeCurrent()
        isRecording = false
        RecordingActivity.isActive = false
        waitingForDevice = false
        isInterrupted = false
        level = 0
        elapsed = 0
        segments = []
        interim = ""
        liveStatus = .off
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Ends the current conversation and immediately starts a new one (recording continues).
    func splitNow() {
        guard isRecording, session != nil else { return }
        rotate()
    }

    // MARK: Sessions

    private func beginSession() {
        let rate = source == .omi ? OmiDeviceManager.shared.currentSampleRate : 16000
        var c = Conversation(source: source, startedAt: Date(), sampleRate: rate)
        c.templateID = settings.defaultTemplate
        store.insert(c)

        var liveOptions: DeepgramLiveClient.Options?
        if settings.transcriptionMode == .live && settings.hasKey("deepgram") {
            let wsBase = settings.baseURL("deepgram")
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
            let appSettings = settings
            liveOptions = DeepgramLiveClient.Options(
                apiKey: settings.apiKey("deepgram"),
                model: settings.deepgramModel,
                language: settings.language,
                sampleRate: rate,
                diarize: settings.diarize,
                keyterms: settings.keytermList,
                apiKeys: settings.orderedKeys("deepgram"),
                endpoint: settings.route("deepgram", wsBase + "/listen"),
                onKeyFailed: { key, reason in appSettings.pauseKey("deepgram", key, seconds: 1800, reason: reason) })
        }
        let pipeline = AudioPipeline(conversationID: c.id, sampleRate: rate, pcmURL: store.rawPCMURL(for: c.id),
                                     live: liveOptions, vadThreshold: settings.vadThreshold)
        let s = Session(id: c.id, pipeline: pipeline, startedAt: c.startedAt)
        let id = c.id
        pipeline.onMeter = { level, voiced, seconds in
            Task { @MainActor in RecordingController.shared.handleMeter(id, level, voiced, seconds) }
        }
        pipeline.onLive = { result in
            Task { @MainActor in RecordingController.shared.handleLive(id, result) }
        }
        pipeline.onLiveStatus = { status in
            Task { @MainActor in RecordingController.shared.handleLiveStatus(id, status) }
        }
        if !pipeline.writerAvailable {
            lastError = "Не удалось создать файл записи (мало места?)"
        }
        session = s
        conversationID = c.id
        segments = []
        interim = ""
        elapsed = 0
        liveStatus = liveOptions == nil ? .off : .connecting
        conversationsThisSession += 1
        pipeline.start()
        box.current = pipeline
    }

    private func rotate() {
        finalizeCurrent()
        if isRecording { beginSession() }
    }

    private func finalizeCurrent() {
        guard let s = session else { return }
        session = nil
        conversationID = nil
        box.current = nil
        finishing[s.id] = s
        store.update(s.id) { c in
            c.segments = s.transcript.segments
            c.duration = s.seconds
        }
        let id = s.id
        s.pipeline.stop { gaps, seconds in
            Task { @MainActor in RecordingController.shared.completeFinalize(id, gaps: gaps, seconds: seconds) }
        }
    }

    private func completeFinalize(_ id: UUID, gaps: Bool, seconds: Double) {
        guard let s = finishing.removeValue(forKey: id) else { return }
        let settings = self.settings
        let mode = settings.transcriptionMode
        let liveUsable = s.pipeline.hasLive && s.liveEverOpened && !s.liveFailed
        let needsBatch = mode == .afterRecording || !liveUsable || gaps || settings.alwaysRetranscribe
        let segments = s.transcript.segments

        store.update(id) { c in
            c.segments = segments
            c.duration = seconds
            c.finishedAt = c.startedAt.addingTimeInterval(seconds)
            c.liveHadGaps = gaps
            c.status = .transcribing
        }

        // Very short accidental recordings without speech are dropped right away.
        if seconds < 2 && segments.isEmpty && settings.deleteEmpty {
            try? FileManager.default.removeItem(at: store.rawPCMURL(for: id))
            store.delete(id)
            return
        }

        let pcm = store.rawPCMURL(for: id)
        let folder = store.folder(for: id)
        let rate = s.pipeline.sampleRate
        let hasSpeechHint = s.hasSpeech
        Task {
            let name: String? = await Task.detached(priority: .utility) { () -> String? in
                try? AudioFiles.finalizeRecording(pcmURL: pcm, sampleRate: rate, folder: folder)
            }.value
            let store = AppStore.shared
            store.update(id) { c in
                c.audioFile = name
                // Skip paid batch transcription when the live result already says "nothing was said".
                let silent = !hasSpeechHint && segments.isEmpty && liveUsable && !gaps
                c.needsBatchTranscription = needsBatch && name != nil && !silent
                c.needsSummary = settings.autoSummarize
                c.status = c.needsBatchTranscription ? .transcribing : .summarizing
            }
            ProcessingQueue.shared.enqueue(id)
        }
    }

    // MARK: Callbacks

    private func handleMeter(_ id: UUID, _ level: Float, _ voiced: Bool, _ seconds: Double) {
        guard let s = session, s.id == id else {
            finishing[id]?.seconds = seconds
            return
        }
        s.seconds = seconds
        self.level = level
        elapsed = seconds
        // Without a working live stream, fall back to the energy VAD for silence detection.
        if voiced && (!s.pipeline.hasLive || s.liveFailed) {
            s.lastSpeechAt = Date()
            s.hasSpeech = true
        }
    }

    private func handleLive(_ id: UUID, _ result: LiveResult) {
        let target: Session? = (session?.id == id) ? session : finishing[id]
        guard let s = target else { return }
        s.transcript.apply(result)
        if result.isFinal && !result.words.isEmpty {
            s.lastSpeechAt = Date()
            s.hasSpeech = true
        } else if !result.isFinal && !result.transcript.isEmpty {
            s.lastSpeechAt = Date()
        }
        if s === session {
            if result.isFinal { segments = s.transcript.segments }
            interim = s.transcript.interim
        }
    }

    private func handleLiveStatus(_ id: UUID, _ status: DeepgramLiveClient.Status) {
        let target: Session? = (session?.id == id) ? session : finishing[id]
        guard let s = target else { return }
        switch status {
        case .open: s.liveEverOpened = true
        case .failed: s.liveFailed = true
        default: break
        }
        guard s === session else { return }
        switch status {
        case .connecting: liveStatus = .connecting
        case .open: liveStatus = .live
        case .reconnecting: liveStatus = .reconnecting
        case .failed(let m): liveStatus = .failed(m)
        case .closed: break
        }
    }

    // MARK: Timer

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in RecordingController.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isRecording else { return }
        let now = Date()

        if let s = session {
            // Periodic save for crash safety.
            if now.timeIntervalSince(s.lastPersist) > 20 {
                s.lastPersist = now
                let segs = s.transcript.segments
                let secs = s.seconds
                store.update(s.id) { c in
                    c.segments = segs
                    c.duration = secs
                }
            }
            // Auto-split after silence.
            let minutes = settings.autoSplitMinutes
            if minutes > 0, s.hasSpeech, now.timeIntervalSince(s.lastSpeechAt) > Double(minutes) * 60 {
                if source == .omi && !OmiDeviceManager.shared.isReady {
                    finalizeCurrent()
                    waitingForDevice = true
                } else {
                    rotate()
                }
                return
            }
        }

        // Omi disconnected for too long → close the conversation, keep waiting for the device.
        if source == .omi, let lost = deviceLostAt, session != nil {
            let limit = Double(max(2, settings.autoSplitMinutes)) * 60
            if now.timeIntervalSince(lost) > limit {
                finalizeCurrent()
                waitingForDevice = true
                deviceLostAt = nil
            }
        }
    }
}
