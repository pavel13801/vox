import Foundation

/// Transcribes a finished audio file: Deepgram, any Whisper-compatible API, or any chat model that accepts audio (Gemini…).
/// Every request uses the provider's keys with automatic failover.
enum BatchTranscriber {
    struct Options {
        var providerID: String
        var engine: STTEngine?
        var title: String
        var baseURL: String
        var model: String
        var language: String
        var diarize: Bool
        var keyterms: [String]
        var custom: Bool
        /// Test exactly this key (no rotation).
        var fixedKey: String? = nil
        /// (chunkIndex, chunkCount) for long files.
        var onProgress: ((Int, Int) -> Void)? = nil
    }

    private static var settings: AppSettings { AppSettings.shared }

    static func transcribe(file: URL, options o: Options) async throws -> [TranscriptSegment] {
        guard let engine = o.engine else {
            throw VoxError.message("\(o.title) не умеет расшифровывать аудио. Выберите другой сервис в Настройки → Расшифровка файла.")
        }
        if !o.custom && o.fixedKey == nil && settings.apiKeys(o.providerID).isEmpty {
            throw VoxError.message("Нет API-ключа для \(o.title). Добавьте его в Настройки → Ключи и провайдеры.")
        }
        if o.model.trimmed.isEmpty { throw VoxError.message("Не выбрана модель расшифровки для \(o.title).") }
        switch engine {
        case .deepgram:
            return try await settings.withKeys(o.providerID, fixedKey: o.fixedKey) { key in try await deepgram(file: file, o, key: key) }
        case .whisper:
            return try await whisper(file: file, o)
        case .chat:
            return try await chatAudio(file: file, o)
        }
    }

    private static func base(_ o: Options) -> String {
        var b = o.baseURL.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private static func send(_ req: URLRequest, body: Data? = nil, file: URL? = nil, _ title: String) async throws -> (Data, URLResponse) {
        do {
            if let file = file { return try await HTTP.session.upload(for: req, fromFile: file) }
            if let body = body { return try await HTTP.session.upload(for: req, from: body) }
            return try await HTTP.session.data(for: req)
        } catch {
            throw APIErrors.network(title, error)
        }
    }

    private static func check(_ response: URLResponse, _ data: Data, _ title: String, _ model: String) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIErrors.make(title, http.statusCode, data, model: model)
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
    }

    private static func deepgram(file: URL, _ o: Options, key: String) async throws -> [TranscriptSegment] {
        guard var comps = URLComponents(string: base(o) + "/listen") else { throw VoxError.message("Неверный адрес Deepgram") }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: o.model),
            URLQueryItem(name: "language", value: o.language),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "utt_split", value: "1.2"),
        ]
        if o.diarize { items.append(URLQueryItem(name: "diarize", value: "true")) }
        let termKey = o.model.hasPrefix("nova-3") ? "keyterm" : "keywords"
        for t in o.keyterms.prefix(50) { items.append(URLQueryItem(name: termKey, value: t)) }
        comps.queryItems = items
        guard let url = comps.url else { throw VoxError.message("Неверный адрес Deepgram") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(AudioFiles.contentType(for: file), forHTTPHeaderField: "Content-Type")

        let (data, response) = try await send(req, file: file, "Deepgram")
        try check(response, data, "Deepgram", o.model)
        let decoded = try JSONDecoder().decode(DGResponse.self, from: data)
        if let utts = decoded.results?.utterances, !utts.isEmpty {
            let raw = utts.compactMap { u -> TranscriptSegment? in
                let text = (u.transcript ?? "").trimmed
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(speaker: u.speaker ?? 0, text: text, start: u.start ?? 0, end: u.end ?? u.start ?? 0)
            }
            return mergeSameSpeaker(raw)
        }
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

    private static func chunks(_ file: URL, seconds: Double) async throws -> (dir: URL, parts: [(url: URL, offset: Double)]) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stt-\(UUID().uuidString)", isDirectory: true)
        let parts = try await Task.detached(priority: .userInitiated) {
            try AudioFiles.splitToWAVChunks(source: file, chunkSeconds: seconds, into: tmp)
        }.value
        return (tmp, parts)
    }

    private static func wavDuration(_ url: URL) -> Double {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        return max(0, (size - 44) / 32000) // 16 kHz × 2 bytes
    }

    // MARK: Whisper-compatible (/audio/transcriptions)

    private struct WhisperSegment: Decodable {
        let start: Double?
        let end: Double?
        let text: String?
    }

    private struct WhisperResponse: Decodable {
        let text: String?
        let segments: [WhisperSegment]?
    }

    private static func whisper(file: URL, _ o: Options) async throws -> [TranscriptSegment] {
        // 10-minute 16 kHz WAV chunks are ~19 MB — below the 25 MB limit of Groq/OpenAI.
        let (dir, parts) = try await chunks(file, seconds: 600)
        defer { try? FileManager.default.removeItem(at: dir) }
        var all: [TranscriptSegment] = []
        for (i, part) in parts.enumerated() {
            o.onProgress?(i, parts.count)
            let segs = try await settings.withKeys(o.providerID, fixedKey: o.fixedKey) { key in
                try await whisperChunk(part.url, offset: part.offset, o, key: key)
            }
            all.append(contentsOf: segs)
        }
        return mergeSameSpeaker(all, maxGap: 2, maxChars: 900)
    }

    private static func whisperChunk(_ url: URL, offset: Double, _ o: Options, key: String) async throws -> [TranscriptSegment] {
        guard let endpoint = URL(string: base(o) + "/audio/transcriptions") else { throw VoxError.message("Неверный адрес API") }
        let verbose = o.model.lowercased().contains("whisper")
        var form = MultipartForm()
        form.addField("model", o.model)
        if o.language != "multi" && !o.language.isEmpty { form.addField("language", o.language) }
        form.addField("response_format", verbose ? "verbose_json" : "json")
        if !o.keyterms.isEmpty { form.addField("prompt", o.keyterms.joined(separator: ", ")) }
        form.addFile("file", filename: url.lastPathComponent, mime: "audio/wav", data: try Data(contentsOf: url))

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(req, body: form.finalize(), o.title)
        try check(response, data, o.title, o.model)
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

    // MARK: Any chat model with audio input (Gemini, OpenRouter, GPT-4o audio…)

    private static let languageNames: [String: String] = [
        "ru": "русском", "en": "английском", "uk": "украинском", "de": "немецком", "es": "испанском",
        "fr": "французском", "it": "итальянском", "pt": "португальском", "tr": "турецком", "kk": "казахском",
    ]

    private static func prompt(_ o: Options) -> String {
        let lang: String
        if o.language == "multi" || languageNames[o.language] == nil {
            lang = "на языке оригинала (если языки смешаны — каждую фразу на её языке)"
        } else {
            lang = "на \(languageNames[o.language] ?? "") языке (иностранные слова оставляй как произнесены)"
        }
        var lines = [
            "Сделай дословную расшифровку этой аудиозаписи \(lang).",
            o.diarize
                ? "Раздели речь по говорящим: Спикер 1, Спикер 2 и т. д. Если голос один — все реплики от Спикера 1."
                : "Все реплики относи к Спикеру 1.",
            "Верни ТОЛЬКО JSON без пояснений:",
            #"{"segments":[{"speaker":1,"start":"MM:SS","text":"реплика"}]}"#,
            "— каждая реплика или законченная мысль отдельным элементом; start — время начала от начала этого фрагмента.",
            #"Пиши всё, что сказано, без сокращений и пересказа, с пунктуацией. Не добавляй ничего от себя. Если речи нет — {"segments":[]}."#,
        ]
        if !o.keyterms.isEmpty { lines.append("Возможные имена и термины: \(o.keyterms.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    private static func chatAudio(file: URL, _ o: Options) async throws -> [TranscriptSegment] {
        // 5-minute 16 kHz WAV pieces: ~9.6 MB each (~13 MB base64) — inside the inline limits of Gemini/OpenRouter.
        let (dir, parts) = try await chunks(file, seconds: 300)
        defer { try? FileManager.default.removeItem(at: dir) }
        var all: [TranscriptSegment] = []
        for (i, part) in parts.enumerated() {
            o.onProgress?(i, parts.count)
            let audio = try Data(contentsOf: part.url).base64EncodedString()
            let duration = wavDuration(part.url)
            let segs = try await settings.withKeys(o.providerID, fixedKey: o.fixedKey) { key in
                try await chatAudioChunk(audio, offset: part.offset, duration: duration, o, key: key)
            }
            all.append(contentsOf: segs)
        }
        return mergeSameSpeaker(all, maxGap: 3, maxChars: 1200)
    }

    private static func chatAudioChunk(_ base64: String, offset: Double, duration: Double, _ o: Options, key: String) async throws -> [TranscriptSegment] {
        guard let url = URL(string: base(o) + "/chat/completions") else { throw VoxError.message("Неверный адрес API") }
        var body: [String: Any] = [
            "model": o.model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt(o)],
                    ["type": "input_audio", "input_audio": ["data": base64, "format": "wav"]],
                ],
            ]],
            "response_format": ["type": "json_object"],
        ]
        func request() throws -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 600
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return req
        }
        var (data, response) = try await send(try request(), o.title)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 200
        var text = String(data: data.prefix(4000), encoding: .utf8) ?? ""
        if status == 400 && text.range(of: "response_format|json_object", options: [.regularExpression, .caseInsensitive]) != nil {
            body.removeValue(forKey: "response_format")
            (data, response) = try await send(try request(), o.title)
            status = (response as? HTTPURLResponse)?.statusCode ?? 200
            text = String(data: data.prefix(4000), encoding: .utf8) ?? ""
        }
        if !(200..<300).contains(status) {
            if status == 400,
               text.range(of: "input_audio|audio input|modalit|does not support audio", options: [.regularExpression, .caseInsensitive]) != nil,
               text.range(of: "location|api key", options: [.regularExpression, .caseInsensitive]) == nil {
                throw VoxError.message("\(o.title): модель «\(o.model)» не принимает аудио. Выберите модель с поддержкой звука (например, Gemini).")
            }
            throw APIErrors.make(o.title, status, data, model: o.model)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let message = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        var reply = ""
        if let s = message?["content"] as? String { reply = s }
        else if let parts = message?["content"] as? [[String: Any]] { reply = parts.compactMap { $0["text"] as? String }.joined() }

        guard let json = LLMClient.extractJSONObject(reply), let list = json["segments"] as? [[String: Any]] else {
            let plain = reply.trimmed
            return plain.isEmpty ? [] : [TranscriptSegment(speaker: 0, text: plain, start: offset, end: offset + duration)]
        }
        var segs: [TranscriptSegment] = list.compactMap { x in
            let t = ((x["text"] as? String) ?? "").trimmed
            guard !t.isEmpty else { return nil }
            let sp: Int
            if let i = x["speaker"] as? Int { sp = i } else if let s = x["speaker"] as? String, let i = Int(s.filter { $0.isNumber }) { sp = i } else { sp = 1 }
            let start = offset + min(parseTime(x["start"]), duration)
            return TranscriptSegment(speaker: max(0, sp - 1), text: t, start: start, end: start)
        }
        for i in segs.indices { segs[i].end = i + 1 < segs.count ? segs[i + 1].start : offset + duration }
        return segs
    }

    private static func parseTime(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        guard let s = v as? String else { return 0 }
        let parts = s.trimmed.split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Checks

    /// Quick key check for Deepgram.
    static func verifyDeepgram(key: String, baseURL: String) async throws {
        var b = baseURL.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + "/projects") else { return }
        var req = URLRequest(url: url)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(req, "Deepgram")
        try check(response, data, "Deepgram", "nova-3")
    }

    /// Checks a transcription setup end-to-end on 1 s of a quiet tone.
    static func verify(options: Options) async throws {
        var pcm = Data(count: 32000)
        pcm.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<p.count { p[i] = Int16(sin(Double(i) / 8) * 200) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vox-check-\(UUID().uuidString).wav")
        try AudioFiles.wavData(pcm: pcm, sampleRate: 16000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await transcribe(file: url, options: options)
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
            if let m = dict["detail"] as? String { return m }
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
