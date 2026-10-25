import Foundation
import Combine

// MARK: - Provider registry

/// How a provider's API looks.
enum ProviderKind: String, Codable, CaseIterable {
    case openai      // OpenAI-compatible: /chat/completions, /models, /audio/transcriptions
    case anthropic   // Anthropic Messages API
    case deepgram    // Deepgram (speech only)
}

/// How a provider transcribes audio files.
enum STTEngine: String, Codable, CaseIterable, Identifiable {
    case deepgram
    case whisper   // /audio/transcriptions
    case chat      // chat model that accepts audio input (Gemini, OpenRouter audio models…)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .whisper: return "Whisper API"
        case .chat: return "Модель с поддержкой аудио"
        }
    }
}

struct ProviderInfo: Identifiable {
    let id: String
    var title: String
    var kind: ProviderKind
    var base: String
    var llm: Bool
    var stt: STTEngine?
    var model: String
    var models: [String]
    var sttModel: String
    var sttModels: [String]
    var hint: String
    var keyURL: String
    /// The provider blocks some countries (Russia): routed through the proxy by default when one is set.
    var blocked: Bool
    var builtin: Bool
}

/// A provider the user added (any OpenAI- or Anthropic-compatible service).
struct CustomProvider: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var kind: ProviderKind
    var base: String
    var model: String
    var stt: STTEngine?
    var sttModel: String
    var url: String
}

struct ProviderPreset: Identifiable {
    let title: String
    let kind: ProviderKind
    let base: String
    let model: String
    let stt: STTEngine?
    let sttModel: String
    let url: String
    var id: String { title }
}

enum Providers {
    static let builtins: [ProviderInfo] = [
        ProviderInfo(id: "deepgram", title: "Deepgram", kind: .deepgram, base: "https://api.deepgram.com/v1", llm: false, stt: .deepgram,
                     model: "", models: [], sttModel: "nova-3", sttModels: ["nova-3", "nova-2"],
                     hint: "console.deepgram.com → API Keys ($200 бесплатно). Live-расшифровка со спикерами.",
                     keyURL: "https://console.deepgram.com", blocked: false, builtin: true),
        ProviderInfo(id: "gemini", title: "Google Gemini", kind: .openai, base: "https://generativelanguage.googleapis.com/v1beta/openai", llm: true, stt: .chat,
                     model: "gemini-3.8-flash", models: ["gemini-3.8-flash", "gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest"],
                     sttModel: "gemini-3.8-flash", sttModels: ["gemini-3.8-flash", "gemini-flash-latest", "gemini-pro-latest"],
                     hint: "aistudio.google.com → Get API key. Ключ начинается с «AIza». Google не обслуживает Россию — нужен VPN или прокси.",
                     keyURL: "https://aistudio.google.com/apikey", blocked: true, builtin: true),
        ProviderInfo(id: "openai", title: "OpenAI", kind: .openai, base: "https://api.openai.com/v1", llm: true, stt: .whisper,
                     model: "gpt-5-mini", models: ["gpt-5-mini", "gpt-5", "gpt-5-nano", "gpt-4.1-mini", "gpt-4o-mini"],
                     sttModel: "whisper-1", sttModels: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"],
                     hint: "platform.openai.com → API keys. Россия заблокирована — нужен VPN или прокси.",
                     keyURL: "https://platform.openai.com/api-keys", blocked: true, builtin: true),
        ProviderInfo(id: "groq", title: "Groq", kind: .openai, base: "https://api.groq.com/openai/v1", llm: true, stt: .whisper,
                     model: "openai/gpt-oss-120b", models: ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "moonshotai/kimi-k2-instruct"],
                     sttModel: "whisper-large-v3", sttModels: ["whisper-large-v3", "whisper-large-v3-turbo"],
                     hint: "console.groq.com → API Keys (бесплатно, есть Whisper для расшифровки).",
                     keyURL: "https://console.groq.com/keys", blocked: false, builtin: true),
        ProviderInfo(id: "openrouter", title: "OpenRouter", kind: .openai, base: "https://openrouter.ai/api/v1", llm: true, stt: .chat,
                     model: "google/gemini-3.8-flash", models: ["google/gemini-3.8-flash", "openai/gpt-5-mini", "anthropic/claude-haiku-5-5", "deepseek/deepseek-chat", "x-ai/grok-4", "qwen/qwen3-max"],
                     sttModel: "google/gemini-3.8-flash", sttModels: ["google/gemini-3.8-flash", "openai/gpt-4o-audio-preview"],
                     hint: "openrouter.ai → Keys. Сотни моделей по одному ключу, работает из России. Расшифровка — через Gemini на OpenRouter.",
                     keyURL: "https://openrouter.ai/keys", blocked: false, builtin: true),
        ProviderInfo(id: "anthropic", title: "Anthropic (Claude)", kind: .anthropic, base: "https://api.anthropic.com/v1", llm: true, stt: nil,
                     model: "claude-haiku-5-5", models: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"], sttModel: "", sttModels: [],
                     hint: "console.anthropic.com → API Keys. Россия заблокирована — нужен VPN или прокси.",
                     keyURL: "https://console.anthropic.com/settings/keys", blocked: true, builtin: true),
        ProviderInfo(id: "deepseek", title: "DeepSeek", kind: .openai, base: "https://api.deepseek.com/v1", llm: true, stt: nil,
                     model: "deepseek-chat", models: ["deepseek-chat", "deepseek-reasoner"], sttModel: "", sttModels: [],
                     hint: "platform.deepseek.com → API keys. Работает из России.",
                     keyURL: "https://platform.deepseek.com/api_keys", blocked: false, builtin: true),
    ]

    static let presets: [ProviderPreset] = [
        ProviderPreset(title: "Mistral", kind: .openai, base: "https://api.mistral.ai/v1", model: "mistral-large-latest", stt: nil, sttModel: "", url: "https://console.mistral.ai/api-keys"),
        ProviderPreset(title: "xAI Grok", kind: .openai, base: "https://api.x.ai/v1", model: "grok-4", stt: nil, sttModel: "", url: "https://console.x.ai"),
        ProviderPreset(title: "Qwen (Alibaba)", kind: .openai, base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen-plus", stt: nil, sttModel: "", url: "https://bailian.console.alibabacloud.com"),
        ProviderPreset(title: "Moonshot Kimi", kind: .openai, base: "https://api.moonshot.ai/v1", model: "kimi-k2-0905-preview", stt: nil, sttModel: "", url: "https://platform.moonshot.ai"),
        ProviderPreset(title: "Together AI", kind: .openai, base: "https://api.together.xyz/v1", model: "meta-llama/Llama-3.3-70B-Instruct-Turbo", stt: nil, sttModel: "", url: "https://api.together.ai"),
        ProviderPreset(title: "Fireworks", kind: .openai, base: "https://api.fireworks.ai/inference/v1", model: "accounts/fireworks/models/llama-v3p3-70b-instruct", stt: .whisper, sttModel: "whisper-v3", url: "https://fireworks.ai"),
        ProviderPreset(title: "Cerebras", kind: .openai, base: "https://api.cerebras.ai/v1", model: "gpt-oss-120b", stt: nil, sttModel: "", url: "https://cloud.cerebras.ai"),
        ProviderPreset(title: "Perplexity", kind: .openai, base: "https://api.perplexity.ai", model: "sonar", stt: nil, sttModel: "", url: "https://www.perplexity.ai/settings/api"),
        ProviderPreset(title: "Ollama / LM Studio", kind: .openai, base: "http://192.168.1.10:11434/v1", model: "llama3.1", stt: nil, sttModel: "", url: ""),
        ProviderPreset(title: "Другой (OpenAI-совместимый)", kind: .openai, base: "", model: "", stt: nil, sttModel: "", url: ""),
        ProviderPreset(title: "Другой (Anthropic-совместимый)", kind: .anthropic, base: "", model: "", stt: nil, sttModel: "", url: ""),
    ]
}

// MARK: - Other option types

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case live
    case afterRecording

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "В реальном времени (Deepgram)"
        case .afterRecording: return "После записи"
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let title: String
    var id: String { code }

    static let all: [LanguageOption] = [
        LanguageOption(code: "ru", title: "Русский"),
        LanguageOption(code: "multi", title: "Мультиязычный (рус + англ и др.)"),
        LanguageOption(code: "en", title: "English"),
        LanguageOption(code: "uk", title: "Українська"),
        LanguageOption(code: "de", title: "Deutsch"),
        LanguageOption(code: "es", title: "Español"),
        LanguageOption(code: "fr", title: "Français"),
        LanguageOption(code: "it", title: "Italiano"),
        LanguageOption(code: "pt", title: "Português"),
        LanguageOption(code: "tr", title: "Türkçe"),
        LanguageOption(code: "kk", title: "Қазақ"),
    ]
}

enum SummaryLanguage: String, CaseIterable, Identifiable {
    case russian
    case auto
    case english

    var id: String { rawValue }
    var title: String {
        switch self {
        case .russian: return "Русский"
        case .auto: return "Как в разговоре"
        case .english: return "English"
        }
    }

    var instruction: String {
        switch self {
        case .russian: return "Пиши все поля строго на русском языке."
        case .auto: return "Пиши на том языке, на котором в основном ведётся разговор."
        case .english: return "Write every field in English."
        }
    }
}

struct LLMConfig {
    var providerID: String
    var kind: ProviderKind
    var title: String
    var baseURL: String
    var apiKey: String
    var model: String
    var custom: Bool
    /// Test exactly this key (no rotation).
    var fixedKey: String?
}

/// API error that keeps HTTP status and body, so key rotation can see why a request failed.
struct APIError: LocalizedError {
    var status: Int
    var body: String
    var message: String
    var noRotate = false

    var errorDescription: String? { message }
}

/// A key's pause after it ran into a limit.
struct KeyPause: Codable {
    var until: Date
    var reason: String
}

// MARK: - Settings store

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard
    private let lock = NSLock()

    // Profile
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }

    // Speech-to-text
    @Published var transcriptionMode: TranscriptionMode { didSet { d.set(transcriptionMode.rawValue, forKey: "transcriptionMode") } }
    @Published var deepgramModel: String { didSet { d.set(deepgramModel, forKey: "deepgramModel") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var diarize: Bool { didSet { d.set(diarize, forKey: "diarize") } }
    @Published var keyterms: String { didSet { d.set(keyterms, forKey: "keyterms") } }
    @Published var batchProvider: String { didSet { d.set(batchProvider, forKey: "batchProviderID") } }
    @Published var alwaysRetranscribe: Bool { didSet { d.set(alwaysRetranscribe, forKey: "alwaysRetranscribe") } }

    // AI
    @Published var llmProvider: String { didSet { d.set(llmProvider, forKey: "llmProviderID") } }
    @Published var summaryLanguage: SummaryLanguage { didSet { d.set(summaryLanguage.rawValue, forKey: "summaryLanguage") } }
    @Published var defaultTemplate: String { didSet { d.set(defaultTemplate, forKey: "defaultTemplate") } }
    @Published var extractMemories: Bool { didSet { d.set(extractMemories, forKey: "extractMemories") } }
    @Published var extractTasks: Bool { didSet { d.set(extractTasks, forKey: "extractTasks") } }
    @Published var customInstructions: String { didSet { d.set(customInstructions, forKey: "customInstructions") } }
    @Published var autoSummarize: Bool { didSet { d.set(autoSummarize, forKey: "autoSummarize") } }
    @Published var maxContextChars: Int { didSet { d.set(maxContextChars, forKey: "maxContextChars") } }

    // Providers & proxy
    @Published var customProviders: [CustomProvider] { didSet { saveCustomProviders() } }
    @Published var proxyURL: String { didSet { d.set(proxyURL.trimmed, forKey: "proxyURL") } }

    // Recording
    @Published var autoSplitMinutes: Int { didSet { d.set(autoSplitMinutes, forKey: "autoSplitMinutes") } }
    @Published var deleteEmpty: Bool { didSet { d.set(deleteEmpty, forKey: "deleteEmpty") } }
    @Published var omiAutoRecord: Bool { didSet { d.set(omiAutoRecord, forKey: "omiAutoRecord") } }
    @Published var backgroundKeepAlive: Bool { didSet { d.set(backgroundKeepAlive, forKey: "backgroundKeepAlive") } }
    @Published var preferredSource: AudioSourceKind { didSet { d.set(preferredSource.rawValue, forKey: "preferredSource") } }
    @Published var vadThreshold: Double { didSet { d.set(vadThreshold, forKey: "vadThreshold") } }

    /// Bumped whenever keys or their pauses change, so views refresh.
    @Published private(set) var keysRevision = 0

    private var pauses: [String: KeyPause] = [:]

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "transcriptionMode": TranscriptionMode.live.rawValue,
            "deepgramModel": "nova-3",
            "language": "ru",
            "diarize": true,
            "alwaysRetranscribe": false,
            "summaryLanguage": SummaryLanguage.russian.rawValue,
            "defaultTemplate": "standard",
            "extractMemories": true,
            "extractTasks": true,
            "autoSummarize": true,
            "maxContextChars": 300_000,
            "autoSplitMinutes": 0,
            "deleteEmpty": true,
            "omiAutoRecord": true,
            "backgroundKeepAlive": true,
            "preferredSource": AudioSourceKind.phone.rawValue,
            "vadThreshold": 0.015,
        ])

        userName = d.string(forKey: "userName") ?? ""
        transcriptionMode = TranscriptionMode(rawValue: d.string(forKey: "transcriptionMode") ?? "") ?? .live
        deepgramModel = d.string(forKey: "deepgramModel") ?? "nova-3"
        language = d.string(forKey: "language") ?? "ru"
        diarize = d.bool(forKey: "diarize")
        keyterms = d.string(forKey: "keyterms") ?? ""
        alwaysRetranscribe = d.bool(forKey: "alwaysRetranscribe")
        summaryLanguage = SummaryLanguage(rawValue: d.string(forKey: "summaryLanguage") ?? "") ?? .russian
        defaultTemplate = d.string(forKey: "defaultTemplate") ?? "standard"
        extractMemories = d.bool(forKey: "extractMemories")
        extractTasks = d.bool(forKey: "extractTasks")
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        autoSummarize = d.bool(forKey: "autoSummarize")
        maxContextChars = d.integer(forKey: "maxContextChars")
        autoSplitMinutes = d.integer(forKey: "autoSplitMinutes")
        deleteEmpty = d.bool(forKey: "deleteEmpty")
        omiAutoRecord = d.bool(forKey: "omiAutoRecord")
        backgroundKeepAlive = d.bool(forKey: "backgroundKeepAlive")
        preferredSource = AudioSourceKind(rawValue: d.string(forKey: "preferredSource") ?? "") ?? .phone
        vadThreshold = d.double(forKey: "vadThreshold")
        proxyURL = d.string(forKey: "proxyURL") ?? ""

        var customs: [CustomProvider] = []
        if let data = d.data(forKey: "customProviders"), let list = try? JSONDecoder().decode([CustomProvider].self, from: data) {
            customs = list
        }

        // Migration from the first version (fixed enum with a single "custom" provider).
        var llm = d.string(forKey: "llmProviderID") ?? ""
        var batch = d.string(forKey: "batchProviderID") ?? ""
        if llm.isEmpty { llm = d.string(forKey: "llmProvider") ?? "gemini" }
        if batch.isEmpty {
            switch d.string(forKey: "batchProvider") ?? "" {
            case "groqWhisper": batch = "groq"
            case "openaiWhisper": batch = "openai"
            default: batch = "deepgram"
            }
            let oldModel = (d.string(forKey: "batchModel") ?? "").trimmed
            if !oldModel.isEmpty && batch != "deepgram" { d.set(oldModel, forKey: "sttModel." + batch) }
        }
        let oldCustomBase = (d.string(forKey: "baseURL.custom") ?? "").trimmed
        if !oldCustomBase.isEmpty && !customs.contains(where: { $0.id == "c_migrated" }) {
            customs.append(CustomProvider(id: "c_migrated", title: "Свой сервер", kind: .openai, base: oldCustomBase,
                                          model: d.string(forKey: "model.custom") ?? "", stt: nil, sttModel: "", url: ""))
            let oldKey = Keychain.get("key.custom")
            if !oldKey.isEmpty { Keychain.set(oldKey, for: "key.c_migrated") }
        }
        if llm == "custom" { llm = oldCustomBase.isEmpty ? "gemini" : "c_migrated" }
        customProviders = customs
        llmProvider = llm
        batchProvider = batch

        if let data = d.data(forKey: "keyPauses.v1"), let p = try? JSONDecoder().decode([String: KeyPause].self, from: data) {
            pauses = p
        }
        if provider(llmProvider) == nil { llmProvider = "gemini" }
        if provider(batchProvider) == nil { batchProvider = "deepgram" }
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) { d.set(data, forKey: "customProviders") }
    }

    // MARK: Registry

    func provider(_ id: String) -> ProviderInfo? {
        if let b = Providers.builtins.first(where: { $0.id == id }) { return b }
        guard let c = customProviders.first(where: { $0.id == id }) else { return nil }
        return ProviderInfo(id: c.id, title: c.title.isEmpty ? "Свой провайдер" : c.title, kind: c.kind, base: c.base,
                            llm: true, stt: c.kind == .anthropic ? nil : c.stt, model: c.model, models: [], sttModel: c.sttModel, sttModels: [],
                            hint: "Свой провайдер: любой сервис с OpenAI- или Anthropic-совместимым API.",
                            keyURL: c.url, blocked: false, builtin: false)
    }

    var providerIDs: [String] { Providers.builtins.map { $0.id } + customProviders.map { $0.id } }
    var llmProviderIDs: [String] { providerIDs.filter { provider($0)?.llm == true } }
    var sttProviderIDs: [String] { providerIDs.filter { sttEngine($0) != nil } }

    func title(_ id: String) -> String { provider(id)?.title ?? id }

    @discardableResult
    func addCustomProvider(_ preset: ProviderPreset) -> String {
        let id = "c_" + UUID().uuidString.prefix(8).lowercased()
        customProviders.append(CustomProvider(id: id, title: preset.title, kind: preset.kind, base: preset.base,
                                              model: preset.model, stt: preset.stt, sttModel: preset.sttModel, url: preset.url))
        return id
    }

    func updateCustomProvider(_ id: String, _ mutate: (inout CustomProvider) -> Void) {
        guard let i = customProviders.firstIndex(where: { $0.id == id }) else { return }
        var c = customProviders[i]
        mutate(&c)
        customProviders[i] = c
    }

    func removeCustomProvider(_ id: String) {
        customProviders.removeAll { $0.id == id }
        setAPIKeys([], for: id)
        if llmProvider == id { llmProvider = "gemini" }
        if batchProvider == id { batchProvider = "deepgram" }
    }

    // MARK: Keys (several per provider, with automatic failover)

    func apiKeys(_ p: String) -> [String] {
        let raw = Keychain.get("keys." + p)
        if !raw.isEmpty, let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) {
            return list.map { $0.trimmed }.filter { !$0.isEmpty }
        }
        let single = Keychain.get("key." + p).trimmed
        return single.isEmpty ? [] : [single]
    }

    func setAPIKeys(_ keys: [String], for p: String) {
        var seen = Set<String>()
        let clean = keys.map { $0.trimmed }.filter { !$0.isEmpty && seen.insert($0).inserted }
        if clean.isEmpty {
            Keychain.set("", for: "keys." + p)
        } else if let data = try? JSONEncoder().encode(clean), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: "keys." + p)
        }
        Keychain.set("", for: "key." + p)
        bumpKeys()
    }

    /// The key used right now: the first one that is not paused.
    func apiKey(_ p: String) -> String { orderedKeys(p).first ?? "" }

    func hasKey(_ p: String) -> Bool {
        guard let info = provider(p) else { return false }
        if !info.builtin { return !info.base.trimmed.isEmpty }
        return !apiKeys(p).isEmpty
    }

    private static func keyID(_ key: String) -> String {
        var h: UInt32 = 5381
        for b in key.utf8 { h = (h &<< 5) &+ h &+ UInt32(b) }
        return String(h, radix: 36) + String(key.count)
    }

    func keyPause(_ p: String, _ key: String) -> KeyPause? {
        lock.lock(); defer { lock.unlock() }
        guard let s = pauses["\(p):\(Self.keyID(key))"], s.until > Date() else { return nil }
        return s
    }

    func pauseKey(_ p: String, _ key: String, seconds: TimeInterval, reason: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        pauses["\(p):\(Self.keyID(key))"] = KeyPause(until: Date().addingTimeInterval(seconds), reason: reason)
        savePausesLocked()
        lock.unlock()
        bumpKeys()
    }

    func clearPause(_ p: String, _ key: String) {
        lock.lock()
        let removed = pauses.removeValue(forKey: "\(p):\(Self.keyID(key))") != nil
        if removed { savePausesLocked() }
        lock.unlock()
        if removed { bumpKeys() }
    }

    private func savePausesLocked() {
        if let data = try? JSONEncoder().encode(pauses) { d.set(data, forKey: "keyPauses.v1") }
    }

    private func bumpKeys() {
        if Thread.isMainThread { keysRevision += 1 } else { DispatchQueue.main.async { self.keysRevision += 1 } }
    }

    /// Free keys first (in the user's order), then paused ones by the time they come back.
    func orderedKeys(_ p: String) -> [String] {
        let keys = apiKeys(p)
        let free = keys.filter { keyPause(p, $0) == nil }
        let paused = keys.filter { keyPause(p, $0) != nil }
            .sorted { (keyPause(p, $0)?.until ?? .distantFuture) < (keyPause(p, $1)?.until ?? .distantFuture) }
        return free + paused
    }

    /// Runs `body` with the provider's keys, switching to the next key when one is out of quota, out of money or rejected.
    func withKeys<T>(_ p: String, fixedKey: String? = nil, _ body: (String) async throws -> T) async throws -> T {
        let keys: [String] = fixedKey.map { [$0] } ?? orderedKeys(p)
        if keys.isEmpty { return try await body("") }
        var lastError: Error?
        for key in keys {
            do {
                let r = try await body(key)
                clearPause(p, key)
                return r
            } catch {
                guard let api = error as? APIError, !api.noRotate, let pause = Self.pauseFor(api) else { throw error }
                pauseKey(p, key, seconds: pause.seconds, reason: pause.reason)
                lastError = error
                if fixedKey != nil { throw error }
            }
        }
        if keys.count > 1, var api = lastError as? APIError {
            let back = keys.compactMap { keyPause(p, $0)?.until }.min()
            let when = back.map { " Ближайший освободится в \(Formatters.time.string(from: $0))." } ?? ""
            api.message += "\n\nВсе ключи (\(keys.count)) сейчас на паузе.\(when)"
            throw api
        }
        throw lastError ?? VoxError.message("Не удалось выполнить запрос")
    }

    /// Seconds until the next midnight in California — when Google resets daily Gemini quotas.
    private static func secondsUntilPacificMidnight() -> TimeInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let now = Date()
        let next = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        return max(60, next.timeIntervalSince(now))
    }

    /// Whether an error means "this key is used up — try the next one", and for how long.
    static func pauseFor(_ e: APIError) -> (seconds: TimeInterval, reason: String)? {
        let text = (e.body + " " + e.message)
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has("location is not supported|unsupported_country|country, region, or territory|not available in your (country|region)") { return nil }
        if e.status == 429 || has("resource_exhausted|quota|rate.?limit|too many requests") {
            if has("per ?day|perday|daily|requests per day") { return (secondsUntilPacificMidnight(), "дневной лимит исчерпан") }
            var seconds: TimeInterval = 65
            if let r = text.range(of: #"retry(Delay)?["\s:]*(in\s*)?"?([0-9.]+)\s*s"#, options: [.regularExpression, .caseInsensitive]) {
                let digits = text[r].filter { $0.isNumber || $0 == "." }
                if let v = Double(digits) { seconds = min(3600, ceil(v) + 2) }
            }
            return (seconds, "лимит запросов в минуту")
        }
        if e.status == 402 || has("insufficient|balance|out of credit|credits? exhausted|payment required") { return (86_400, "закончились деньги на счёте") }
        if e.status == 401 || has("api key not valid|api_key_invalid|pass a valid api key|invalid[_ ]api[_ ]key|incorrect api key|invalid x-api-key|invalid credentials") {
            return (3600, "ключ не принят")
        }
        if e.status == 403 { return (3600, "нет доступа") }
        return nil
    }

    // MARK: Models, URLs, engines

    func model(_ p: String) -> String {
        let v = (d.string(forKey: "model." + p) ?? "").trimmed
        if !v.isEmpty { return v }
        return provider(p)?.model ?? ""
    }

    func setModel(_ value: String, for p: String) {
        if provider(p)?.builtin == false {
            updateCustomProvider(p) { $0.model = value.trimmed }
        } else {
            objectWillChange.send()
            d.set(value.trimmed, forKey: "model." + p)
        }
    }

    func baseURL(_ p: String) -> String {
        guard let info = provider(p) else { return "" }
        if !info.builtin { return info.base }
        let v = (d.string(forKey: "baseURL." + p) ?? "").trimmed
        return v.isEmpty ? info.base : v
    }

    func baseURLOverride(_ p: String) -> String { d.string(forKey: "baseURL." + p) ?? "" }

    func setBaseURL(_ value: String, for p: String) {
        if provider(p)?.builtin == false {
            updateCustomProvider(p) { $0.base = value.trimmed }
        } else {
            objectWillChange.send()
            d.set(value.trimmed, forKey: "baseURL." + p)
        }
    }

    func sttEngine(_ p: String) -> STTEngine? {
        guard let info = provider(p) else { return nil }
        if info.kind == .deepgram { return .deepgram }
        if info.kind == .anthropic { return nil }
        if let raw = d.string(forKey: "sttEngine." + p), let e = STTEngine(rawValue: raw) { return e }
        return info.stt
    }

    func setSTTEngine(_ e: STTEngine?, for p: String) {
        objectWillChange.send()
        d.set(e?.rawValue, forKey: "sttEngine." + p)
    }

    func sttModel(_ p: String) -> String {
        if p == "deepgram" { return deepgramModel }
        let v = (d.string(forKey: "sttModel." + p) ?? "").trimmed
        if !v.isEmpty { return v }
        if let info = provider(p), !info.sttModel.isEmpty { return info.sttModel }
        return sttEngine(p) == .chat ? model(p) : "whisper-1"
    }

    func sttModelOverride(_ p: String) -> String { d.string(forKey: "sttModel." + p) ?? "" }

    func setSTTModel(_ value: String, for p: String) {
        objectWillChange.send()
        d.set(value.trimmed, forKey: "sttModel." + p)
    }

    // MARK: Proxy

    func usesProxy(_ p: String) -> Bool {
        guard !proxyURL.trimmed.isEmpty else { return false }
        if d.object(forKey: "useProxy." + p) != nil { return d.bool(forKey: "useProxy." + p) }
        return provider(p)?.blocked ?? false
    }

    func setUsesProxy(_ v: Bool, for p: String) {
        objectWillChange.send()
        d.set(v, forKey: "useProxy." + p)
    }

    /// https://host/path → <proxy>/host/path (wss:// too) when the provider goes through the proxy.
    func route(_ p: String, _ url: String) -> String {
        guard usesProxy(p) else { return url }
        var proxy = proxyURL.trimmed
        while proxy.hasSuffix("/") { proxy.removeLast() }
        for scheme in ["https://", "http://", "wss://", "ws://"] where url.hasPrefix(scheme) {
            let rest = String(url.dropFirst(scheme.count))
            if scheme.hasPrefix("ws") {
                let wsProxy = proxy.hasPrefix("https://") ? "wss://" + proxy.dropFirst(8) : (proxy.hasPrefix("http://") ? "ws://" + proxy.dropFirst(7) : proxy)
                return wsProxy + "/" + rest
            }
            return proxy + "/" + rest
        }
        return url
    }

    // MARK: Derived configs

    func llmConfig(for p: String, fixedKey: String? = nil) -> LLMConfig {
        let info = provider(p) ?? provider("gemini")!
        return LLMConfig(providerID: p, kind: info.kind, title: info.title, baseURL: route(p, baseURL(p)),
                         apiKey: apiKey(p), model: model(p), custom: !info.builtin, fixedKey: fixedKey)
    }

    var llmConfig: LLMConfig { llmConfig(for: llmProvider) }

    var llmConfigured: Bool { hasKey(llmProvider) }

    var keytermList: [String] {
        keyterms.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    func batchOptions(for p: String? = nil) -> BatchTranscriber.Options {
        let id = p ?? batchProvider
        let info = provider(id) ?? provider("deepgram")!
        return BatchTranscriber.Options(
            providerID: id,
            engine: sttEngine(id),
            title: info.title,
            baseURL: route(id, baseURL(id)),
            model: sttModel(id),
            language: language,
            diarize: diarize,
            keyterms: keytermList,
            custom: !info.builtin)
    }
}
