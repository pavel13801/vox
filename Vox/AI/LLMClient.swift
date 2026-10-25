import Foundation

struct LLMMessage {
    var role: String // "user" | "assistant"
    var content: String
}

/// Turns provider errors into actionable Russian messages and keeps status/body for key rotation.
enum APIErrors {
    static func detail(_ data: Data) -> String { HTTP.extractError(data) ?? "" }

    static func message(_ title: String, _ status: Int, _ body: String, model: String = "") -> String {
        let d = HTTP.extractError(Data(body.utf8)) ?? ""
        let all = d + " " + String(body.prefix(2000))
        func has(_ pattern: String) -> Bool { all.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has("location is not supported|unsupported_country|country, region, or territory|not available in your (country|region)|request not allowed") {
            return "\(title): сервис недоступен из вашей страны (запросы из России блокируются). Включите VPN на телефоне или настройте прокси: Настройки → Прокси. Ещё вариант — OpenRouter или DeepSeek, они работают из России."
        }
        if [500, 502, 503, 504, 529].contains(status) || has("overloaded|\"unavailable\"|status.{0,4}unavailable|try again later") {
            return "\(title): сервер перегружен или временно недоступен (\(status)). Это на стороне сервиса, а не ваших ключей: Vox повторил запрос несколько раз и пробовал запасную модель. Попробуйте чуть позже или выберите другую модель. \(d)"
        }
        if has("resource_exhausted|quota|rate.?limit|too many requests") || status == 429 {
            return "\(title): превышен лимит запросов или квота. \(d)"
        }
        if has("api key not valid|api_key_invalid|pass a valid api key|invalid[_ ]api[_ ]key|incorrect api key|invalid x-api-key|invalid credentials") || status == 401 {
            return "\(title): ключ не подходит. Проверьте, что он скопирован целиком, без пробелов, и выдан именно для \(title). (\(status)) \(d)"
        }
        if status == 404 || has("model_not_found|no such model|unknown model|is not found|does not exist") {
            return "\(title): модель «\(model)» не найдена. Нажмите «Загрузить список» рядом с моделью и выберите доступную. (\(status)) \(d)"
        }
        if status == 402 || has("insufficient|balance|out of credit") { return "\(title): недостаточно средств на счёте. \(d)" }
        if status == 403 { return "\(title): нет доступа (403). Возможно, ключ без нужных прав или страна заблокирована. \(d)" }
        if status == 413 { return "\(title): файл слишком большой. \(d)" }
        return "\(title): ошибка \(status). \(d)"
    }

    static func make(_ title: String, _ status: Int, _ data: Data, model: String = "") -> APIError {
        let body = String(data: data.prefix(20_000), encoding: .utf8) ?? ""
        return APIError(status: status, body: body, message: message(title, status, body, model: model))
    }

    /// Network failure (no internet, timeout, blocked address). Status -1 marks it as temporary for retries.
    static func network(_ title: String, _ error: Error) -> Error {
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return error }
        return APIError(status: -1, body: "network",
                        message: "Не удалось связаться с \(title): нет интернета или адрес заблокирован. Попробуйте VPN или прокси (Настройки → Прокси). (\(error.localizedDescription))")
    }
}

/// Retries for temporary failures: overloaded servers (HTTP 503 "The model is overloaded"), 5xx, network drops.
enum Retry {
    static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? APIError, !e.noRotate else { return false }
        if e.status == -1 || [500, 502, 503, 504, 529].contains(e.status) { return true }
        return e.body.range(of: "overloaded|\"UNAVAILABLE\"|try again later", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Runs `body` up to `attempts` times, waiting 2 s, 5 s, 12 s… between temporary failures.
    static func run<T>(attempts: Int = 4, _ body: () async throws -> T) async throws -> T {
        var delay: Double = 2
        var lastError: Error = VoxError.message("Не удалось выполнить запрос")
        for attempt in 0..<max(1, attempts) {
            do {
                return try await body()
            } catch {
                lastError = error
                guard isTransient(error), attempt < attempts - 1, !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2.5
            }
        }
        throw lastError
    }

    /// Tries the chosen model, then the provider's fallback models while the error is "server overloaded".
    static func withFallbackModels<T>(_ providerID: String, model: String, _ body: (String) async throws -> T) async throws -> T {
        do {
            return try await body(model)
        } catch {
            guard isTransient(error) else { throw error }
            var lastError = error
            let fallbacks = (AppSettings.shared.provider(providerID)?.fallbackModels ?? []).filter { $0 != model }
            for m in fallbacks {
                do {
                    return try await body(m)
                } catch {
                    guard isTransient(error) else { throw error }
                    lastError = error
                }
            }
            throw lastError
        }
    }
}

/// Minimal client for OpenAI-compatible chat APIs (OpenAI, Gemini, Groq, OpenRouter, DeepSeek, Mistral, local servers…)
/// and the Anthropic Messages API. Every request goes through the provider's keys with automatic failover.
enum LLMClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg)
    }()

    private static var settings: AppSettings { AppSettings.shared }

    private static func endpoint(_ config: LLMConfig, _ path: String) throws -> URL {
        var base = config.baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + path) else { throw VoxError.message("Не задан или неверен адрес API для \(config.title).") }
        return url
    }

    private static func ensureConfigured(_ config: LLMConfig) throws {
        if !config.custom && config.apiKey.isEmpty {
            throw VoxError.message("Нет API-ключа для \(config.title). Добавьте его в Настройки → Ключи и провайдеры.")
        }
        if config.model.trimmed.isEmpty {
            throw VoxError.message("Не выбрана модель для \(config.title).")
        }
    }

    /// model fallback (on overload) → key rotation (on limits) → retries with pauses (on temporary errors).
    private static func withKeys<T>(_ config: LLMConfig, retries: Int = 4, _ body: (LLMConfig) async throws -> T) async throws -> T {
        try await Retry.withFallbackModels(config.providerID, model: config.model) { model in
            try await settings.withKeys(config.providerID, fixedKey: config.fixedKey) { key in
                var c = config
                c.apiKey = key
                c.model = model
                return try await Retry.run(attempts: retries) { try await body(c) }
            }
        }
    }

    // MARK: Request building

    private static func makeRequest(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool, stream: Bool) throws -> URLRequest {
        try ensureConfigured(config)
        var req: URLRequest
        var body: [String: Any]
        if config.kind == .anthropic {
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
            if config.providerID == "openrouter" {
                req.setValue("https://github.com/pavel13801/vox", forHTTPHeaderField: "HTTP-Referer")
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

    private static func send(_ req: URLRequest, _ title: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw APIErrors.network(title, error)
        }
    }

    // MARK: Non-streaming

    static func complete(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool = false) async throws -> String {
        try await withKeys(config) { c in
            do {
                return try await completeOnce(c, system: system, messages: messages, json: json)
            } catch let e as APIError where json && e.status == 400 && e.body.range(of: "response_format|json", options: [.regularExpression, .caseInsensitive]) != nil {
                // Some models/providers don't support response_format — retry without it.
                return try await completeOnce(c, system: system, messages: messages, json: false)
            }
        }
    }

    private static func completeOnce(_ config: LLMConfig, system: String, messages: [LLMMessage], json: Bool) async throws -> String {
        let req = try makeRequest(config, system: system, messages: messages, json: json, stream: false)
        let (data, response) = try await send(req, config.title)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIErrors.make(config.title, http.statusCode, data, model: config.model)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoxError.message("Пустой ответ модели")
        }
        if config.kind == .anthropic {
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

    // MARK: Streaming

    static func stream(_ config: LLMConfig, system: String, messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withKeys(config) { c in
                        var emitted = false
                        do {
                            try await streamOnce(c, system: system, messages: messages) { piece in
                                emitted = true
                                continuation.yield(piece)
                            }
                        } catch var e as APIError {
                            // Part of the answer is already shown — do not repeat it with another key.
                            if emitted { e.noRotate = true }
                            throw e
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamOnce(_ config: LLMConfig, system: String, messages: [LLMMessage], onPiece: (String) -> Void) async throws {
        let req = try makeRequest(config, system: system, messages: messages, json: false, stream: true)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw APIErrors.network(config.title, error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 20_000 { break }
            }
            throw APIErrors.make(config.title, http.statusCode, data, model: config.model)
        }
        var gotAny = false
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any], err["message"] is String {
                let code = (err["code"] as? Int) ?? 0
                throw APIErrors.make(config.title, code, d, model: config.model)
            }
            var piece: String?
            if config.kind == .anthropic {
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
                onPiece(p)
            }
        }
        if !gotAny && !Task.isCancelled {
            // Fallback for providers that ignore "stream": do a normal request.
            onPiece(try await completeOnce(config, system: system, messages: messages, json: false))
        }
    }

    // MARK: Models list

    static func listModels(_ config: LLMConfig) async throws -> [String] {
        try await withKeys(config) { c in try await listModelsOnce(c) }
    }

    private static func listModelsOnce(_ config: LLMConfig) async throws -> [String] {
        var req = URLRequest(url: try endpoint(config, "/models"))
        if config.kind == .anthropic {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await send(req, config.title)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIErrors.make(config.title, http.statusCode, data, model: config.model)
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
