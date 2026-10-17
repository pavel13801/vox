import Foundation

struct LLMMessage {
    var role: String // "user" | "assistant"
    var content: String
}

/// Minimal client for OpenAI-compatible chat APIs (OpenAI, Gemini, Groq, OpenRouter, DeepSeek, local servers)
/// and the Anthropic Messages API.
enum LLMClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg)
    }()

    private static func endpoint(_ config: LLMConfig, _ path: String) throws -> URL {
        var base = config.baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw VoxError.message("Неверный адрес API: \(base)") }
        return url
    }

    private static func ensureConfigured(_ config: LLMConfig) throws {
        if config.provider != .custom && config.apiKey.isEmpty {
            throw VoxError.message("Нет API-ключа для \(config.provider.title). Добавьте его в Настройки → Ключи API.")
        }
        if config.model.trimmed.isEmpty {
            throw VoxError.message("Не выбрана модель для \(config.provider.title).")
        }
    }

    // MARK: Request building

    private static func makeRequest(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool, stream: Bool) throws -> URLRequest {
        try ensureConfigured(config)
        var req: URLRequest
        var body: [String: Any]
        if config.provider == .anthropic {
            req = URLRequest(url: try endpoint(config, "/messages"))
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 16000,
                "system": system,
                "messages": messages.map { ["role": $0.role, "content": $0.content] },
            ]
            if stream { body["stream"] = true }
        } else {
            req = URLRequest(url: try endpoint(config, "/chat/completions"))
            if !config.apiKey.isEmpty {
                req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            if config.provider == .openrouter {
                req.setValue("https://github.com/vox-app", forHTTPHeaderField: "HTTP-Referer")
                req.setValue("Vox", forHTTPHeaderField: "X-Title")
            }
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })
            body = ["model": config.model, "messages": msgs]
            if json { body["response_format"] = ["type": "json_object"] }
            if stream { body["stream"] = true }
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300
        return req
    }

    // MARK: Non-streaming

    static func complete(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool = false) async throws -> String {
        do {
            return try await completeOnce(config, system: system, messages: messages, json: json)
        } catch let error as LLMHTTPError where json && error.status == 400 {
            // Some models/providers don't support response_format — retry without it.
            return try await completeOnce(config, system: system, messages: messages, json: false)
        }
    }

    private struct LLMHTTPError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    private static func completeOnce(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool) async throws -> String {
        let req = try makeRequest(config, system: system, messages: messages, json: json, stream: false)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMHTTPError(status: http.statusCode, message: describe(http.statusCode, data, config))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoxError.message("Пустой ответ модели")
        }
        if config.provider == .anthropic {
            let blocks = obj["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            if text.isEmpty { throw VoxError.message("Модель вернула пустой ответ") }
            return text
        }
        let choices = obj["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        if let text = message?["content"] as? String, !text.isEmpty { return text }
        if let parts = message?["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw VoxError.message("Модель вернула пустой ответ")
    }

    private static func describe(_ status: Int, _ data: Data, _ config: LLMConfig) -> String {
        let detail = HTTP.extractError(data) ?? ""
        switch status {
        case 401, 403: return "\(config.provider.title): неверный ключ или нет доступа. \(detail)"
        case 404: return "\(config.provider.title): модель «\(config.model)» не найдена. Выберите другую в настройках. \(detail)"
        case 429: return "\(config.provider.title): превышен лимит запросов. Подождите и повторите. \(detail)"
        case 402: return "\(config.provider.title): недостаточно средств. \(detail)"
        default: return "\(config.provider.title): ошибка \(status). \(detail)"
        }
    }

    // MARK: Streaming

    static func stream(_ config: LLMConfig, system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try makeRequest(config, system: system, messages: messages, json: false, stream: true)
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 20_000 { break }
                        }
                        throw VoxError.message(describe(http.statusCode, data, config))
                    }
                    var gotAny = false
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
                            throw VoxError.message(m)
                        }
                        var piece: String?
                        if config.provider == .anthropic {
                            if obj["type"] as? String == "content_block_delta",
                               let delta = obj["delta"] as? [String: Any] {
                                piece = delta["text"] as? String
                            }
                        } else if let choices = obj["choices"] as? [[String: Any]],
                                  let delta = choices.first?["delta"] as? [String: Any] {
                            piece = delta["content"] as? String
                        }
                        if let p = piece, !p.isEmpty {
                            gotAny = true
                            continuation.yield(p)
                        }
                    }
                    if !gotAny && !Task.isCancelled {
                        // Fallback for providers that ignore "stream": do a normal request.
                        let text = try await complete(config, system: system, messages: messages)
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Models list

    static func listModels(_ config: LLMConfig) async throws -> [String] {
        var req = URLRequest(url: try endpoint(config, "/models"))
        if config.provider == .anthropic {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoxError.message(describe(http.statusCode, data, config))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (obj["data"] as? [[String: Any]]) ?? (obj["models"] as? [[String: Any]]) ?? []
        var ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        ids = ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        let skip = ["embedding", "embed", "tts", "whisper", "dall-e", "image", "moderation", "audio", "transcribe", "realtime", "guard"]
        ids = ids.filter { id in !skip.contains { id.lowercased().contains($0) } }
        return Array(Set(ids)).sorted()
    }

    /// Extracts the first JSON object from a model reply (tolerates ```json fences and extra prose).
    static func extractJSONObject(_ text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return obj
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let d = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
