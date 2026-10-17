import Foundation

/// Transcribes a finished audio file in one go (better diarization, works offline-first).
enum BatchTranscriber {
    struct Options {
        var provider: BatchSTTProvider
        var apiKey: String
        var baseURL: String
        var model: String
        var language: String
        var diarize: Bool
        var keyterms: [String]
    }

    static func transcribe(file: URL, options: Options) async throws -> [TranscriptSegment] {
        guard !options.apiKey.isEmpty else {
            throw VoxError.message("Нет API-ключа для \(options.provider.apiProvider.title). Добавьте его в Настройках.")
        }
        switch options.provider {
        case .deepgram:
            return try await deepgram(file: file, options: options)
        case .groqWhisper, .openaiWhisper:
            return try await whisper(file: file, options: options)
        }
    }

    // MARK: Deepgram pre-recorded

    private struct DGUtterance: Decodable {
        let start: Double?
        let end: Double?
        let transcript: String?
        let speaker: Int?
    }

    private struct DGResults: Decodable {
        let channels: [DGChannel]?
        let utterances: [DGUtterance]?
    }

    private struct DGResponse: Decodable {
        let results: DGResults?
        let err_msg: String?
    }

    static func deepgram(file: URL, options: Options) async throws -> [TranscriptSegment] {
        guard var comps = URLComponents(string: "https://api.deepgram.com/v1/listen") else { throw VoxError.message("URL") }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: options.model),
            URLQueryItem(name: "language", value: options.language),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "utt_split", value: "1.2"),
        ]
        if options.diarize { items.append(URLQueryItem(name: "diarize", value: "true")) }
        let termKey = options.model.hasPrefix("nova-3") ? "keyterm" : "keywords"
        for t in options.keyterms.prefix(50) { items.append(URLQueryItem(name: termKey, value: t)) }
        comps.queryItems = items
        guard let url = comps.url else { throw VoxError.message("URL") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("Token \(options.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(AudioFiles.contentType(for: file), forHTTPHeaderField: "Content-Type")

        let (data, response) = try await HTTP.session.upload(for: req, fromFile: file)
        try HTTP.check(response, data, service: "Deepgram")
        let decoded = try JSONDecoder().decode(DGResponse.self, from: data)
        if let utts = decoded.results?.utterances, !utts.isEmpty {
            let raw = utts.compactMap { u -> TranscriptSegment? in
                let text = (u.transcript ?? "").trimmed
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(speaker: u.speaker ?? 0, text: text, start: u.start ?? 0, end: u.end ?? u.start ?? 0)
            }
            return mergeSameSpeaker(raw)
        }
        // Fallback: build from words
        let words = decoded.results?.channels?.first?.alternatives?.first?.words ?? []
        var segs: [TranscriptSegment] = []
        for w in words {
            let text = (w.punctuated_word ?? w.word ?? "").trimmed
            guard !text.isEmpty else { continue }
            let speaker = w.speaker ?? 0
            if var last = segs.last, last.speaker == speaker {
                last.text += " " + text
                last.end = w.end ?? last.end
                segs[segs.count - 1] = last
            } else {
                segs.append(TranscriptSegment(speaker: speaker, text: text, start: w.start ?? 0, end: w.end ?? 0))
            }
        }
        if segs.isEmpty, let t = decoded.results?.channels?.first?.alternatives?.first?.transcript?.trimmed, !t.isEmpty {
            segs = [TranscriptSegment(speaker: 0, text: t, start: 0, end: 0)]
        }
        return segs
    }

    static func mergeSameSpeaker(_ segs: [TranscriptSegment], maxGap: Double = 3, maxChars: Int = 1200) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for s in segs {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end <= maxGap, last.text.count + s.text.count <= maxChars {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Whisper (OpenAI-compatible)

    private struct WhisperSegment: Decodable {
        let start: Double?
        let end: Double?
        let text: String?
    }

    private struct WhisperResponse: Decodable {
        let text: String?
        let segments: [WhisperSegment]?
    }

    static func whisper(file: URL, options: Options) async throws -> [TranscriptSegment] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 10-minute 16 kHz WAV chunks are ~19 MB — below the 25 MB limit of Groq/OpenAI.
        let chunks = try await Task.detached(priority: .userInitiated) {
            try AudioFiles.splitToWAVChunks(source: file, chunkSeconds: 600, into: tmp)
        }.value
        var all: [TranscriptSegment] = []
        for chunk in chunks {
            let segs = try await whisperChunk(chunk.url, offset: chunk.offset, options: options)
            all.append(contentsOf: segs)
        }
        return mergeSameSpeaker(all, maxGap: 2, maxChars: 900)
    }

    private static func whisperChunk(_ url: URL, offset: Double, options: Options) async throws -> [TranscriptSegment] {
        let base = options.baseURL.hasSuffix("/") ? String(options.baseURL.dropLast()) : options.baseURL
        guard let endpoint = URL(string: base + "/audio/transcriptions") else { throw VoxError.message("Неверный адрес API") }
        let verbose = options.model.contains("whisper")
        var form = MultipartForm()
        form.addField("model", options.model)
        if options.language != "multi" && !options.language.isEmpty {
            form.addField("language", options.language)
        }
        form.addField("response_format", verbose ? "verbose_json" : "json")
        if !options.keyterms.isEmpty {
            form.addField("prompt", options.keyterms.joined(separator: ", "))
        }
        form.addFile("file", filename: url.lastPathComponent, mime: "audio/wav", data: try Data(contentsOf: url))

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await HTTP.session.upload(for: req, from: form.finalize())
        try HTTP.check(response, data, service: options.provider.apiProvider.title)
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        if let segs = decoded.segments, !segs.isEmpty {
            return segs.compactMap { s in
                let text = (s.text ?? "").trimmed
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(speaker: 0, text: text, start: offset + (s.start ?? 0), end: offset + (s.end ?? 0))
            }
        }
        let text = (decoded.text ?? "").trimmed
        return text.isEmpty ? [] : [TranscriptSegment(speaker: 0, text: text, start: offset, end: offset)]
    }

    /// Quick key check for Deepgram.
    static func verifyDeepgram(key: String) async throws {
        guard let url = URL(string: "https://api.deepgram.com/v1/projects") else { return }
        var req = URLRequest(url: url)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.session.data(for: req)
        try HTTP.check(response, data, service: "Deepgram")
    }
}

// MARK: - HTTP helpers

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    static func check(_ response: URLResponse, _ data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = extractError(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        switch http.statusCode {
        case 401, 403:
            throw VoxError.message("\(service): неверный API-ключ или нет доступа (\(http.statusCode)). \(message)")
        case 402:
            throw VoxError.message("\(service): закончился баланс. \(message)")
        case 429:
            throw VoxError.message("\(service): превышен лимит запросов, попробуйте позже. \(message)")
        default:
            throw VoxError.message("\(service): ошибка \(http.statusCode). \(message)")
        }
    }

    static func extractError(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            let s = String(data: data.prefix(300), encoding: .utf8)?.trimmed
            return (s?.isEmpty ?? true) ? nil : s
        }
        if let dict = obj as? [String: Any] {
            if let e = dict["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = dict["error"] as? String { return e }
            if let m = dict["err_msg"] as? String { return m }
            if let m = dict["message"] as? String { return m }
        }
        if let arr = obj as? [[String: Any]], let first = arr.first,
           let e = first["error"] as? [String: Any], let m = e["message"] as? String {
            return m
        }
        return nil
    }
}

struct MultipartForm {
    let boundary = "VoxBoundary-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalize() -> Data {
        var d = body
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }
}
