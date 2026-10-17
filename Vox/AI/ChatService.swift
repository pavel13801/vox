import Foundation
import Combine

/// "Ask your recordings": builds a context from memories, conversation summaries and the most relevant
/// full transcripts, then streams the model's answer.
@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published private(set) var isResponding = false
    private var currentTask: Task<Void, Never>?

    /// Per-conversation chats are kept in memory only.
    @Published var scopedMessages: [UUID: [ChatMessage]] = [:]

    func send(_ text: String, scope: UUID? = nil) {
        let question = text.trimmed
        guard !question.isEmpty, !isResponding else { return }
        let store = AppStore.shared
        let settings = AppSettings.shared

        let userMsg = ChatMessage(role: "user", text: question)
        let answer = ChatMessage(role: "assistant", text: "")
        var history: [ChatMessage]
        if let scope = scope {
            history = scopedMessages[scope] ?? []
            scopedMessages[scope, default: []].append(userMsg)
            scopedMessages[scope, default: []].append(answer)
        } else {
            history = store.chatMessages
            store.appendChat(userMsg)
            store.appendChat(answer)
        }

        let config = settings.llmConfig
        let system = buildSystemPrompt(question: question, scope: scope, maxChars: settings.maxContextChars)
        var messages: [LLMMessage] = history.suffix(12).filter { !$0.isError && !$0.text.isEmpty }
            .map { LLMMessage(role: $0.role, content: $0.text) }
        messages.append(LLMMessage(role: "user", content: question))

        isResponding = true
        currentTask = Task { [weak self] in
            var acc = ""
            var lastFlush = Date()
            do {
                for try await piece in LLMClient.stream(config, system: system, messages: messages) {
                    acc += piece
                    if Date().timeIntervalSince(lastFlush) > 0.08 {
                        lastFlush = Date()
                        self?.setAnswer(answer.id, acc, scope: scope, persist: false)
                    }
                }
                self?.setAnswer(answer.id, acc.isEmpty ? "(пустой ответ)" : acc, scope: scope, persist: true)
            } catch {
                let msg = acc.isEmpty ? "⚠️ \(error.localizedDescription)" : acc + "\n\n⚠️ \(error.localizedDescription)"
                self?.setAnswer(answer.id, msg, scope: scope, persist: true, isError: acc.isEmpty)
            }
            self?.isResponding = false
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        isResponding = false
    }

    func clear(scope: UUID?) {
        stop()
        if let scope = scope {
            scopedMessages[scope] = []
        } else {
            AppStore.shared.clearChat()
        }
    }

    private func setAnswer(_ id: UUID, _ text: String, scope: UUID?, persist: Bool, isError: Bool = false) {
        if let scope = scope {
            guard var list = scopedMessages[scope], let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].text = text
            list[i].isError = isError
            scopedMessages[scope] = list
        } else {
            AppStore.shared.updateChat(id, text: text, isError: isError, persist: persist)
        }
    }

    // MARK: Context

    private func buildSystemPrompt(question: String, scope: UUID?, maxChars: Int) -> String {
        let store = AppStore.shared
        let settings = AppSettings.shared
        let budget = max(30_000, maxChars)
        var s = """
        Ты — личный ассистент пользователя приложения-диктофона Vox. У тебя есть доступ к его записям: \
        расшифровкам разговоров, встреч, лекций и диктовок, к их сводкам, задачам и фактам о пользователе. \
        Отвечай по существу, опираясь на записи; если ссылаешься на запись — указывай её дату и название. \
        Если в записях нет ответа — честно скажи об этом, можешь ответить из общих знаний, явно пометив это. \
        Расшифровки автоматические и могут содержать ошибки распознавания. \
        Отвечай на языке вопроса. Можно использовать Markdown.
        Сегодня: \(Formatters.longDateTime.string(from: Date())).

        """
        if !settings.userName.trimmed.isEmpty {
            s += "Пользователя зовут \(settings.userName.trimmed).\n"
        }

        if let scope = scope, let c = store.conversation(scope) {
            s += "\nВопросы касаются одной конкретной записи.\n\n"
            s += conversationBlock(c, fullTranscript: true, transcriptLimit: budget)
            return s
        }

        if !store.memories.isEmpty {
            s += "\nФАКТЫ О ПОЛЬЗОВАТЕЛЕ:\n"
            for m in store.memories.prefix(200) { s += "- \(m.text)\n" }
        }
        let open = store.actionItems.filter { !$0.done }
        if !open.isEmpty {
            s += "\nОТКРЫТЫЕ ЗАДАЧИ:\n"
            for t in open.prefix(100) {
                let due = t.dueDate.map { " (до \(Formatters.isoDay.string(from: $0)))" } ?? ""
                s += "- \(t.text)\(due)\n"
            }
        }

        let convs = store.conversations.filter { $0.status != .recording || $0.hasSpeech }
        let ranked = rank(convs, question: question)
        var used = s.count

        // Full transcripts for the most relevant conversations (≈60% of the budget).
        let transcriptBudget = Int(Double(budget) * 0.6)
        var fullIDs = Set<UUID>()
        var fullBlocks = ""
        for c in ranked where used + fullBlocks.count < transcriptBudget {
            let remaining = transcriptBudget - used - fullBlocks.count
            guard remaining > 2_000 else { break }
            fullBlocks += conversationBlock(c, fullTranscript: true, transcriptLimit: remaining)
            fullIDs.insert(c.id)
        }
        if !fullBlocks.isEmpty {
            s += "\nНАИБОЛЕЕ ПОДХОДЯЩИЕ К ВОПРОСУ ЗАПИСИ (с расшифровкой):\n\n" + fullBlocks
        }
        used = s.count

        // Summaries of the rest, newest first.
        var index = ""
        for c in convs where !fullIDs.contains(c.id) {
            let line = summaryLine(c)
            if used + index.count + line.count > budget { break }
            index += line
        }
        if !index.isEmpty {
            s += "\nДРУГИЕ ЗАПИСИ (только сводки, новые сверху):\n" + index
        }
        return s
    }

    private func conversationBlock(_ c: Conversation, fullTranscript: Bool, transcriptLimit: Int) -> String {
        var b = "=== \(c.emoji) \(c.displayTitle) — \(Formatters.longDateTime.string(from: c.startedAt)), \(Formatters.duration(c.duration)) ===\n"
        if !c.overview.isEmpty { b += "Сводка: \(c.overview)\n" }
        if !c.keyPoints.isEmpty { b += "Тезисы: " + c.keyPoints.joined(separator: "; ") + "\n" }
        if fullTranscript && !c.segments.isEmpty {
            var t = c.formattedTranscript()
            if t.count > transcriptLimit {
                t = String(t.prefix(transcriptLimit)) + "\n…(расшифровка обрезана)"
            }
            b += "Расшифровка:\n\(t)\n"
        }
        return b + "\n"
    }

    private func summaryLine(_ c: Conversation) -> String {
        let date = Formatters.shortDateTime.string(from: c.startedAt)
        var overview = c.overview.replacingOccurrences(of: "\n", with: " ")
        if overview.isEmpty { overview = String(c.plainTranscript.prefix(200)) }
        if overview.count > 400 { overview = String(overview.prefix(400)) + "…" }
        return "- [\(date)] \(c.emoji) \(c.displayTitle): \(overview)\n"
    }

    /// Cheap relevance ranking: crude stemming + term counts + date hints.
    private func rank(_ convs: [Conversation], question: String) -> [Conversation] {
        let q = question.lowercased()
        let stems = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !Self.stopWords.contains($0) }
            .map { String($0.prefix(max(4, min(6, $0.count - 2)))) }

        let cal = Calendar.current
        var dayFilter: ((Date) -> Bool)?
        if q.contains("сегодня") { dayFilter = { cal.isDateInToday($0) } }
        else if q.contains("вчера") { dayFilter = { cal.isDateInYesterday($0) } }
        else if q.contains("недел") { dayFilter = { Date().timeIntervalSince($0) < 7 * 86_400 } }

        var scored: [(Conversation, Double)] = []
        for c in convs {
            var score = 0.0
            if let f = dayFilter, f(c.startedAt) { score += 50 }
            if !stems.isEmpty {
                let hay = (c.title + " " + c.overview + " " + c.keyPoints.joined(separator: " ") + " " + c.plainTranscript).lowercased()
                for st in stems {
                    let n = hay.components(separatedBy: st).count - 1
                    if n > 0 { score += 5 + min(Double(n), 20) }
                }
                let head = (c.title + " " + c.overview).lowercased()
                for st in stems where head.contains(st) { score += 10 }
            }
            if score > 0 { scored.append((c, score)) }
        }
        if scored.isEmpty {
            // Nothing matched — fall back to the latest conversations.
            return Array(convs.prefix(3))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(8).map { $0.0 }
    }

    private static let stopWords: Set<String> = [
        "какой", "какая", "какие", "когда", "почему", "зачем", "сколько", "который", "которые", "этот", "этой", "этом",
        "было", "были", "была", "будет", "есть", "меня", "мной", "мне", "тебя", "чтобы", "только", "очень", "можно",
        "нужно", "надо", "что-то", "about", "what", "when", "which", "where", "there", "have", "this", "that",
        "расскажи", "напомни", "скажи", "говорил", "говорили", "сказал", "сказали", "запись", "записи", "разговор",
    ]
}
