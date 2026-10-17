import Foundation
import Combine

// MARK: - Providers

enum APIProvider: String, CaseIterable, Identifiable, Codable {
    case deepgram
    case openai
    case gemini
    case groq
    case openrouter
    case anthropic
    case deepseek
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .anthropic: return "Anthropic (Claude)"
        case .deepseek: return "DeepSeek"
        case .custom: return "Свой сервер (OpenAI-совместимый)"
        }
    }

    var keyHint: String {
        switch self {
        case .deepgram: return "console.deepgram.com → API Keys ($200 бесплатно)"
        case .openai: return "platform.openai.com → API keys"
        case .gemini: return "aistudio.google.com → Get API key (есть бесплатный лимит)"
        case .groq: return "console.groq.com → API Keys (бесплатно)"
        case .openrouter: return "openrouter.ai → Keys"
        case .anthropic: return "console.anthropic.com → API Keys"
        case .deepseek: return "platform.deepseek.com → API keys"
        case .custom: return "Ключ вашего сервера (можно оставить пустым)"
        }
    }

    var keyURL: URL? {
        switch self {
        case .deepgram: return URL(string: "https://console.deepgram.com")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .custom: return nil
        }
    }

    /// Providers usable as a chat LLM.
    static var llmProviders: [APIProvider] { [.gemini, .openai, .groq, .openrouter, .anthropic, .deepseek, .custom] }

    var defaultBaseURL: String {
        switch self {
        case .deepgram: return "https://api.deepgram.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .custom: return "http://192.168.1.10:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepgram: return "nova-3"
        case .openai: return "gpt-5-mini"
        case .gemini: return "gemini-flash-latest"
        case .groq: return "openai/gpt-oss-120b"
        case .openrouter: return "google/gemini-2.5-flash"
        case .anthropic: return "claude-haiku-5-5"
        case .deepseek: return "deepseek-chat"
        case .custom: return "llama3.1"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .deepgram: return ["nova-3", "nova-2"]
        case .openai: return ["gpt-5-mini", "gpt-5", "gpt-5-nano", "gpt-4.1-mini", "gpt-4o-mini"]
        case .gemini: return ["gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest", "gemini-2.5-flash"]
        case .groq: return ["openai/gpt-oss-120b", "llama-3.3-70b-versatile", "moonshotai/kimi-k2-instruct"]
        case .openrouter: return ["google/gemini-2.5-flash", "openai/gpt-5-mini", "anthropic/claude-haiku-5-5", "deepseek/deepseek-chat"]
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .custom: return []
        }
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case live
    case afterRecording

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "В реальном времени"
        case .afterRecording: return "После записи (дешевле)"
        }
    }
}

enum BatchSTTProvider: String, CaseIterable, Identifiable {
    case deepgram
    case groqWhisper
    case openaiWhisper

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepgram: return "Deepgram (со спикерами)"
        case .groqWhisper: return "Groq Whisper (бесплатно, без спикеров)"
        case .openaiWhisper: return "OpenAI Whisper"
        }
    }

    var apiProvider: APIProvider {
        switch self {
        case .deepgram: return .deepgram
        case .groqWhisper: return .groq
        case .openaiWhisper: return .openai
        }
    }

    var defaultModel: String {
        switch self {
        case .deepgram: return "nova-3"
        case .groqWhisper: return "whisper-large-v3"
        case .openaiWhisper: return "whisper-1"
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

// MARK: - Settings store

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // Profile
    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }

    // Speech-to-text
    @Published var transcriptionMode: TranscriptionMode { didSet { d.set(transcriptionMode.rawValue, forKey: "transcriptionMode") } }
    @Published var deepgramModel: String { didSet { d.set(deepgramModel, forKey: "deepgramModel") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var diarize: Bool { didSet { d.set(diarize, forKey: "diarize") } }
    @Published var keyterms: String { didSet { d.set(keyterms, forKey: "keyterms") } }
    @Published var batchProvider: BatchSTTProvider { didSet { d.set(batchProvider.rawValue, forKey: "batchProvider") } }
    @Published var batchModel: String { didSet { d.set(batchModel, forKey: "batchModel") } }
    @Published var alwaysRetranscribe: Bool { didSet { d.set(alwaysRetranscribe, forKey: "alwaysRetranscribe") } }

    // AI
    @Published var llmProvider: APIProvider { didSet { d.set(llmProvider.rawValue, forKey: "llmProvider") } }
    @Published var summaryLanguage: SummaryLanguage { didSet { d.set(summaryLanguage.rawValue, forKey: "summaryLanguage") } }
    @Published var defaultTemplate: String { didSet { d.set(defaultTemplate, forKey: "defaultTemplate") } }
    @Published var extractMemories: Bool { didSet { d.set(extractMemories, forKey: "extractMemories") } }
    @Published var extractTasks: Bool { didSet { d.set(extractTasks, forKey: "extractTasks") } }
    @Published var customInstructions: String { didSet { d.set(customInstructions, forKey: "customInstructions") } }
    @Published var autoSummarize: Bool { didSet { d.set(autoSummarize, forKey: "autoSummarize") } }
    @Published var maxContextChars: Int { didSet { d.set(maxContextChars, forKey: "maxContextChars") } }

    // Recording
    @Published var autoSplitMinutes: Int { didSet { d.set(autoSplitMinutes, forKey: "autoSplitMinutes") } }
    @Published var deleteEmpty: Bool { didSet { d.set(deleteEmpty, forKey: "deleteEmpty") } }
    @Published var omiAutoRecord: Bool { didSet { d.set(omiAutoRecord, forKey: "omiAutoRecord") } }
    @Published var backgroundKeepAlive: Bool { didSet { d.set(backgroundKeepAlive, forKey: "backgroundKeepAlive") } }
    @Published var preferredSource: AudioSourceKind { didSet { d.set(preferredSource.rawValue, forKey: "preferredSource") } }
    @Published var vadThreshold: Double { didSet { d.set(vadThreshold, forKey: "vadThreshold") } }

    // Revision counter so views refresh after keys change
    @Published private(set) var keysRevision = 0

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "transcriptionMode": TranscriptionMode.live.rawValue,
            "deepgramModel": "nova-3",
            "language": "ru",
            "diarize": true,
            "batchProvider": BatchSTTProvider.deepgram.rawValue,
            "batchModel": "",
            "alwaysRetranscribe": false,
            "llmProvider": APIProvider.gemini.rawValue,
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
        batchProvider = BatchSTTProvider(rawValue: d.string(forKey: "batchProvider") ?? "") ?? .deepgram
        batchModel = d.string(forKey: "batchModel") ?? ""
        alwaysRetranscribe = d.bool(forKey: "alwaysRetranscribe")
        llmProvider = APIProvider(rawValue: d.string(forKey: "llmProvider") ?? "") ?? .gemini
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
    }

    // MARK: Keys & per-provider options

    func apiKey(_ p: APIProvider) -> String { Keychain.get("key." + p.rawValue) }

    func setAPIKey(_ value: String, for p: APIProvider) {
        Keychain.set(value, for: "key." + p.rawValue)
        keysRevision += 1
    }

    func hasKey(_ p: APIProvider) -> Bool {
        if p == .custom { return !(d.string(forKey: "baseURL.custom") ?? "").isEmpty }
        return !apiKey(p).isEmpty
    }

    func model(_ p: APIProvider) -> String {
        let v = d.string(forKey: "model." + p.rawValue) ?? ""
        return v.isEmpty ? p.defaultModel : v
    }

    func setModel(_ value: String, for p: APIProvider) {
        objectWillChange.send()
        d.set(value.trimmed, forKey: "model." + p.rawValue)
    }

    func baseURL(_ p: APIProvider) -> String {
        let v = d.string(forKey: "baseURL." + p.rawValue) ?? ""
        return v.isEmpty ? p.defaultBaseURL : v
    }

    func setBaseURL(_ value: String, for p: APIProvider) {
        objectWillChange.send()
        d.set(value.trimmed, forKey: "baseURL." + p.rawValue)
    }

    var llmConfig: LLMConfig {
        LLMConfig(provider: llmProvider,
                  baseURL: baseURL(llmProvider),
                  apiKey: apiKey(llmProvider),
                  model: model(llmProvider))
    }

    var llmConfigured: Bool { hasKey(llmProvider) }

    var effectiveBatchModel: String {
        batchModel.trimmed.isEmpty ? batchProvider.defaultModel : batchModel.trimmed
    }

    var keytermList: [String] {
        keyterms.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }
}

struct LLMConfig {
    var provider: APIProvider
    var baseURL: String
    var apiKey: String
    var model: String
}
