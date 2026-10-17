import Foundation

// MARK: - Transcript

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id: UUID
    var speaker: Int
    var text: String
    var start: Double
    var end: Double

    init(id: UUID = UUID(), speaker: Int, text: String, start: Double, end: Double) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speaker = try c.decodeIfPresent(Int.self, forKey: .speaker) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
    }
}

// MARK: - Conversation

enum ConversationStatus: String, Codable {
    case recording
    case transcribing
    case summarizing
    case done
    case failed

    var label: String {
        switch self {
        case .recording: return "Идёт запись"
        case .transcribing: return "Расшифровка…"
        case .summarizing: return "Анализ ИИ…"
        case .done: return "Готово"
        case .failed: return "Ошибка"
        }
    }
}

enum AudioSourceKind: String, Codable, CaseIterable, Identifiable {
    case phone
    case omi
    case imported

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phone: return "iPhone"
        case .omi: return "Omi"
        case .imported: return "Импорт"
        }
    }

    var systemImage: String {
        switch self {
        case .phone: return "iphone"
        case .omi: return "circle.circle"
        case .imported: return "square.and.arrow.down"
        }
    }
}

struct Conversation: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var title: String
    var emoji: String
    var category: String
    var overview: String
    var keyPoints: [String]
    var segments: [TranscriptSegment]
    var speakerNames: [String: String]
    var status: ConversationStatus
    var source: AudioSourceKind
    var audioFile: String?
    var duration: Double
    var errorMessage: String?
    var needsBatchTranscription: Bool
    var needsSummary: Bool
    var templateID: String
    var starred: Bool
    var liveHadGaps: Bool
    var sampleRate: Double
    var userEditedTitle: Bool

    init(id: UUID = UUID(), source: AudioSourceKind, startedAt: Date = Date(), sampleRate: Double = 16000) {
        self.id = id
        self.createdAt = Date()
        self.startedAt = startedAt
        self.finishedAt = nil
        self.title = ""
        self.emoji = "🎙️"
        self.category = ""
        self.overview = ""
        self.keyPoints = []
        self.segments = []
        self.speakerNames = [:]
        self.status = .recording
        self.source = source
        self.audioFile = nil
        self.duration = 0
        self.errorMessage = nil
        self.needsBatchTranscription = false
        self.needsSummary = true
        self.templateID = "standard"
        self.starred = false
        self.liveHadGaps = false
        self.sampleRate = sampleRate
        self.userEditedTitle = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? createdAt
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🎙️"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        status = (try? c.decodeIfPresent(ConversationStatus.self, forKey: .status)) ?? .done
        source = (try? c.decodeIfPresent(AudioSourceKind.self, forKey: .source)) ?? .phone
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        needsBatchTranscription = try c.decodeIfPresent(Bool.self, forKey: .needsBatchTranscription) ?? false
        needsSummary = try c.decodeIfPresent(Bool.self, forKey: .needsSummary) ?? false
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID) ?? "standard"
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        liveHadGaps = try c.decodeIfPresent(Bool.self, forKey: .liveHadGaps) ?? false
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 16000
        userEditedTitle = try c.decodeIfPresent(Bool.self, forKey: .userEditedTitle) ?? false
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return "Запись " + Formatters.shortDateTime.string(from: startedAt)
    }

    var isProcessing: Bool {
        status == .transcribing || status == .summarizing
    }

    var hasSpeech: Bool {
        segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    var plainTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    var speakers: [Int] {
        var seen: [Int] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    func speakerName(_ speaker: Int) -> String {
        if let name = speakerNames[String(speaker)], !name.isEmpty { return name }
        return "Спикер \(speaker + 1)"
    }

    /// Transcript formatted for LLM prompts and exports.
    func formattedTranscript(withTimestamps: Bool = true) -> String {
        var lines: [String] = []
        lines.reserveCapacity(segments.count)
        for s in segments {
            let ts = withTimestamps ? "[\(Formatters.clock(s.start))] " : ""
            lines.append("\(ts)\(speakerName(s.speaker)): \(s.text)")
        }
        return lines.joined(separator: "\n")
    }

    func markdown(actionItems: [ActionItem]) -> String {
        var md = "# \(emoji) \(displayTitle)\n\n"
        md += "- Дата: \(Formatters.longDateTime.string(from: startedAt))\n"
        md += "- Длительность: \(Formatters.duration(duration))\n"
        if !category.isEmpty { md += "- Категория: \(category)\n" }
        md += "- Источник: \(source.label)\n\n"
        if !overview.isEmpty {
            md += "## Сводка\n\n\(overview)\n\n"
        }
        if !keyPoints.isEmpty {
            md += "## Ключевые моменты\n\n"
            for p in keyPoints { md += "- \(p)\n" }
            md += "\n"
        }
        if !actionItems.isEmpty {
            md += "## Задачи\n\n"
            for a in actionItems { md += "- [\(a.done ? "x" : " ")] \(a.text)\n" }
            md += "\n"
        }
        if !segments.isEmpty {
            md += "## Транскрипт\n\n"
            for s in segments {
                md += "**\(speakerName(s.speaker))** _[\(Formatters.clock(s.start))]_: \(s.text)\n\n"
            }
        }
        return md
    }
}

// MARK: - Action items

struct ActionItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var done: Bool
    var createdAt: Date
    var conversationID: UUID?
    var dueDate: Date?
    var completedAt: Date?

    init(id: UUID = UUID(), text: String, conversationID: UUID? = nil, dueDate: Date? = nil) {
        self.id = id
        self.text = text
        self.done = false
        self.createdAt = Date()
        self.conversationID = conversationID
        self.dueDate = dueDate
        self.completedAt = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

// MARK: - Memories

struct MemoryItem: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var conversationID: UUID?

    init(id: UUID = UUID(), text: String, conversationID: UUID? = nil) {
        self.id = id
        self.text = text
        self.createdAt = Date()
        self.conversationID = conversationID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
    }
}

// MARK: - Chat

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: UUID
    var role: String // "user" | "assistant"
    var text: String
    var createdAt: Date
    var isError: Bool

    init(id: UUID = UUID(), role: String, text: String, isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.isError = isError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

// MARK: - Formatters

enum Formatters {
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    static let longDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        return dayHeader.string(from: date).capitalizedFirst
    }

    /// 0:05, 12:03, 1:02:03
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// "1 ч 5 мин", "12 мин", "40 сек"
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(total) сек"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
