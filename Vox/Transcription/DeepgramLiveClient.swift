import Foundation

// MARK: - Wire models

struct DGWord: Decodable {
    let word: String?
    let punctuated_word: String?
    let start: Double?
    let end: Double?
    let speaker: Int?
    let confidence: Double?
}

struct DGAlternative: Decodable {
    let transcript: String?
    let words: [DGWord]?
}

struct DGChannel: Decodable {
    let alternatives: [DGAlternative]?
}

struct DGLiveMessage: Decodable {
    let type: String?
    let is_final: Bool?
    let speech_final: Bool?
    let start: Double?
    let duration: Double?
    let channel: DGChannel?
}

struct LiveWord {
    let text: String
    let start: Double
    let end: Double
    let speaker: Int
}

/// A Deepgram result with times already moved onto the recording timeline.
struct LiveResult {
    let isFinal: Bool
    let transcript: String
    let words: [LiveWord]
    let start: Double
    let end: Double
}

// MARK: - Client

/// Streams PCM to Deepgram over a WebSocket. Reconnects automatically and buffers audio while offline,
/// so short network drops do not lose speech. All internal state lives on a private serial queue.
final class DeepgramLiveClient: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case connecting
        case open
        case reconnecting(Int)
        case failed(String)
        case closed
    }

    struct Options {
        var apiKey: String
        var model: String
        var language: String
        var sampleRate: Double
        var diarize: Bool
        var keyterms: [String]
    }

    var onStatus: ((Status) -> Void)?
    var onResult: ((LiveResult) -> Void)?

    private let opts: Options
    private let q = DispatchQueue(label: "vox.deepgram.live")
    private lazy var delegateQueue: OperationQueue = {
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        oq.underlyingQueue = q
        return oq
    }()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var running = false
    private var finishing = false
    private var attempt = 0
    private var gaps = false

    private var pending: [(data: Data, t0: Double)] = []
    private var pendingBytes = 0
    private let maxPendingBytes: Int

    private var timeline: Double = 0
    private var connectionBase: Double = 0
    private var baseSet = false
    private var lastSendAt = Date()
    private var keepAlive: DispatchSourceTimer?
    private var finishCompletion: ((Bool) -> Void)?

    init(options: Options) {
        self.opts = options
        // Keep up to ~2 minutes of audio while reconnecting.
        self.maxPendingBytes = Int(options.sampleRate * 2 * 120)
        super.init()
    }

    // MARK: Public

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            self.session = URLSession(configuration: .default, delegate: self, delegateQueue: self.delegateQueue)
            self.connect()
            self.startKeepAlive()
        }
    }

    func send(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        q.async {
            let t0 = self.timeline
            self.timeline += Double(pcm.count) / 2.0 / self.opts.sampleRate
            guard self.running || self.finishing else { return }
            if self.isOpen, let task = self.task {
                if !self.baseSet {
                    self.connectionBase = t0
                    self.baseSet = true
                }
                self.transmit(pcm, on: task)
            } else {
                self.pending.append((pcm, t0))
                self.pendingBytes += pcm.count
                while self.pendingBytes > self.maxPendingBytes, !self.pending.isEmpty {
                    let first = self.pending.removeFirst()
                    self.pendingBytes -= first.data.count
                    self.gaps = true
                }
            }
        }
    }

    /// Flushes remaining audio, asks Deepgram for final results and closes.
    /// Completion runs on an internal queue; its argument is true if some audio may be missing from the live transcript.
    func finish(_ completion: @escaping (Bool) -> Void) {
        q.async {
            self.running = false
            self.finishing = true
            self.finishCompletion = completion
            if self.isOpen, let task = self.task {
                self.flushPending(on: task)
                task.send(.string("{\"type\":\"CloseStream\"}")) { _ in }
                self.q.asyncAfter(deadline: .now() + 6) { self.completeFinish() }
            } else {
                if !self.pending.isEmpty { self.gaps = true }
                self.completeFinish()
            }
        }
    }

    /// Immediately tears everything down without waiting for final results.
    func cancel() {
        q.async {
            self.running = false
            self.finishing = false
            self.finishCompletion = nil
            self.teardown()
        }
    }

    // MARK: Connection

    private func buildRequest() -> URLRequest? {
        guard var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen") else { return nil }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: opts.model),
            URLQueryItem(name: "language", value: opts.language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(opts.sampleRate))),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
        ]
        if opts.diarize { items.append(URLQueryItem(name: "diarize", value: "true")) }
        if opts.model.hasPrefix("nova-3") {
            for term in opts.keyterms.prefix(50) { items.append(URLQueryItem(name: "keyterm", value: term)) }
        } else {
            for term in opts.keyterms.prefix(50) { items.append(URLQueryItem(name: "keywords", value: term)) }
        }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Token \(opts.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        return req
    }

    private func connect() {
        guard running, let session = session, let req = buildRequest() else { return }
        isOpen = false
        baseSet = false
        onStatus?(attempt == 0 ? .connecting : .reconnecting(attempt))
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self, t === self.task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): self.handle(Data(s.utf8))
                case .data(let d): self.handle(d)
                @unknown default: break
                }
                self.receive(on: t)
            case .failure(let error):
                self.connectionEnded(t, error: error)
            }
        }
    }

    private func transmit(_ data: Data, on task: URLSessionWebSocketTask) {
        lastSendAt = Date()
        task.send(.data(data)) { [weak self] error in
            if error != nil { self?.gaps = true }
        }
    }

    private func flushPending(on task: URLSessionWebSocketTask) {
        guard !pending.isEmpty else { return }
        if !baseSet, let first = pending.first {
            connectionBase = first.t0
            baseSet = true
        }
        for chunk in pending { transmit(chunk.data, on: task) }
        pending.removeAll()
        pendingBytes = 0
    }

    private func connectionEnded(_ t: URLSessionWebSocketTask, error: Error?) {
        guard t === task else { return }
        let wasOpen = isOpen
        isOpen = false
        task = nil
        if finishing {
            completeFinish()
            return
        }
        guard running else { return }

        let status = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            running = false
            onStatus?(.failed("Deepgram: неверный API-ключ или нет доступа"))
            return
        }
        if status == 400 {
            running = false
            onStatus?(.failed("Deepgram отклонил параметры (модель/язык). Проверьте настройки."))
            return
        }
        if status == 402 {
            running = false
            onStatus?(.failed("Deepgram: закончился баланс"))
            return
        }
        if wasOpen { gaps = true }
        attempt += 1
        let delay = min(15.0, pow(2.0, Double(min(attempt, 5) - 1)))
        onStatus?(.reconnecting(attempt))
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func completeFinish() {
        guard let completion = finishCompletion else { return }
        finishCompletion = nil
        finishing = false
        teardown()
        onStatus?(.closed)
        completion(gaps)
    }

    private func teardown() {
        keepAlive?.cancel()
        keepAlive = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isOpen = false
        session?.invalidateAndCancel()
        session = nil
    }

    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isOpen, let task = self.task else { return }
            if Date().timeIntervalSince(self.lastSendAt) > 3.5 {
                task.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
                self.lastSendAt = Date()
            }
        }
        timer.resume()
        keepAlive = timer
    }

    // MARK: Messages

    private func handle(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(DGLiveMessage.self, from: data) else { return }
        guard msg.type == nil || msg.type == "Results" else { return }
        guard let alt = msg.channel?.alternatives?.first else { return }
        let transcript = (alt.transcript ?? "").trimmed
        let base = connectionBase
        let words: [LiveWord] = (alt.words ?? []).compactMap { w in
            let text = (w.punctuated_word ?? w.word ?? "").trimmed
            guard !text.isEmpty else { return nil }
            return LiveWord(text: text,
                            start: base + (w.start ?? 0),
                            end: base + (w.end ?? w.start ?? 0),
                            speaker: w.speaker ?? 0)
        }
        let start = base + (msg.start ?? 0)
        let end = start + (msg.duration ?? 0)
        let result = LiveResult(isFinal: msg.is_final ?? false, transcript: transcript, words: words, start: start, end: end)
        onResult?(result)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        isOpen = true
        attempt = 0
        onStatus?(.open)
        flushPending(on: webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connectionEnded(webSocketTask, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        connectionEnded(ws, error: error)
    }
}
