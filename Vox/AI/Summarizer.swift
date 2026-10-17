import Foundation

struct SummaryTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let instructions: String

    static let all: [SummaryTemplate] = [
        SummaryTemplate(id: "standard", title: "Сводка", icon: "text.alignleft", instructions: """
        Поле overview: связный пересказ сути разговора в 3–8 предложениях: о чём шла речь, к чему пришли, что важно запомнить. \
        Если разговор длинный — можно разбить на короткие абзацы.
        """),
        SummaryTemplate(id: "meeting", title: "Встреча / протокол", icon: "person.3", instructions: """
        Поле overview: протокол встречи в Markdown с разделами **Участники**, **Обсуждали**, **Решения**, **Открытые вопросы**, \
        **Следующие шаги**. Под каждым — маркированный список. Указывай, кто что сказал или пообещал, если это понятно.
        """),
        SummaryTemplate(id: "lecture", title: "Лекция / конспект", icon: "graduationcap", instructions: """
        Поле overview: подробный структурированный конспект в Markdown: заголовки ### по темам, под ними тезисы, \
        определения, формулы, примеры, выводы. Сохраняй все важные факты, цифры и термины.
        """),
        SummaryTemplate(id: "call", title: "Звонок / переговоры", icon: "phone", instructions: """
        Поле overview: в Markdown — **Суть звонка**, **Договорённости** (кто, что, когда, суммы), **Условия и цифры**, \
        **Риски и спорные моменты**.
        """),
        SummaryTemplate(id: "interview", title: "Интервью", icon: "mic", instructions: """
        Поле overview: в Markdown — краткое введение (кто и о чём), затем ключевые вопросы и ответы в формате \
        **В:** … / **О:** …, в конце — главные выводы.
        """),
        SummaryTemplate(id: "ideas", title: "Идеи / мозговой штурм", icon: "lightbulb", instructions: """
        Поле overview: в Markdown — сгруппированный список всех высказанных идей (### группа, под ней пункты), \
        для каждой идеи — одна строка сути; в конце — самые перспективные идеи.
        """),
        SummaryTemplate(id: "diary", title: "Дневник / мысли", icon: "book", instructions: """
        Поле overview: бережный пересказ от второго лица («Ты рассказал…»): события, мысли, чувства, \
        инсайты. В конце одна строка о настроении.
        """),
        SummaryTemplate(id: "dictation", title: "Чистовой текст диктовки", icon: "doc.text", instructions: """
        Поле overview: полный чистовой текст диктовки — сохрани ВСЁ содержание и порядок мыслей, но убери слова-паразиты, \
        повторы и оговорки, расставь пунктуацию и абзацы. Ничего не сокращай и не добавляй от себя.
        """),
    ]

    static func byID(_ id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? all[0]
    }
}

struct SummaryResult {
    var title: String
    var emoji: String
    var category: String
    var overview: String
    var keyPoints: [String]
    var actionItems: [(text: String, due: Date?)]
    var memories: [String]
    var speakerNames: [String: String]
}

enum Summarizer {
    static let categories = ["Работа", "Личное", "Учёба", "Здоровье", "Финансы", "Идеи", "Семья", "Покупки",
                             "Путешествия", "Технологии", "Встреча", "Другое"]

    struct Context {
        var userName: String
        var language: SummaryLanguage
        var customInstructions: String
        var extractTasks: Bool
        var extractMemories: Bool
        var existingMemories: [String]
        var maxChars: Int
    }

    static func summarize(_ c: Conversation, template: SummaryTemplate, config: LLMConfig, context ctx: Context) async throws -> SummaryResult {
        var transcript = c.formattedTranscript()
        var isNotes = false
        let limit = max(40_000, ctx.maxChars)
        if transcript.count > limit {
            transcript = try await condense(c, config: config, chunkChars: limit / 2)
            isNotes = true
        }

        let system = buildSystemPrompt(template: template, ctx: ctx)
        var user = "Дата и время записи: \(Formatters.longDateTime.string(from: c.startedAt)) (сегодня \(Formatters.isoDay.string(from: Date()))).\n"
        user += "Длительность: \(Formatters.duration(c.duration)).\n\n"
        if isNotes {
            user += "Запись очень длинная, поэтому ниже — подробные конспекты её частей по порядку.\n\n"
            user += "КОНСПЕКТЫ:\n\(transcript)"
        } else {
            user += "ТРАНСКРИПТ:\n\(transcript)"
        }

        let reply = try await LLMClient.complete(config, system: system, messages: [LLMMessage(role: "user", content: user)], json: true)
        guard let obj = LLMClient.extractJSONObject(reply) else {
            // Model ignored the JSON format — keep its text as the overview.
            return SummaryResult(title: "", emoji: "🎙️", category: "", overview: reply.trimmed, keyPoints: [],
                                 actionItems: [], memories: [], speakerNames: [:])
        }
        return parse(obj)
    }

    private static func buildSystemPrompt(template: SummaryTemplate, ctx: Context) -> String {
        var s = """
        Ты — аккуратный ассистент-аналитик. Тебе дают расшифровку аудиозаписи (разговор, встреча, лекция или диктовка). \
        Расшифровка сделана автоматически: в ней бывают ошибки распознавания и перепутанные спикеры — понимай смысл по контексту. \
        Не выдумывай фактов, которых нет в записи.

        \(ctx.language.instruction)

        Верни ТОЛЬКО один JSON-объект (без ``` и пояснений) со схемой:
        {
          "title": "короткое ёмкое название, 3–8 слов, без кавычек и даты",
          "emoji": "один подходящий эмодзи",
          "category": "одна из: \(categories.joined(separator: ", "))",
          "overview": "строка (можно Markdown) — см. инструкцию ниже",
          "key_points": ["3–10 самых важных тезисов, фактов, цифр"],
          "action_items": [{"text": "конкретное действие, начинай с глагола", "due": "YYYY-MM-DD или null"}],
          "memories": ["долговременные факты о пользователе"],
          "speaker_names": {"0": "Имя"}
        }

        Инструкция для overview:
        \(template.instructions)

        """
        if ctx.extractTasks {
            s += """
            action_items: только реальные задачи, обещания и договорённости, которые нужно выполнить пользователю \
            (или которые он поручил/принял). Не придумывай задач. Относительные сроки («завтра», «в пятницу») переводи в дату \
            относительно даты записи. Если задач нет — пустой массив.

            """
        } else {
            s += "action_items: всегда пустой массив.\n\n"
        }
        if ctx.extractMemories {
            s += """
            memories: 0–5 новых устойчивых фактов о самом пользователе, полезных в будущем (люди в его жизни, предпочтения, \
            планы, работа, здоровье, важные даты). Формулируй от третьего лица одной фразой. Не повторяй уже известные факты. \
            Мелочи и содержание чужих разговоров сюда не попадают.

            """
            if !ctx.existingMemories.isEmpty {
                s += "Уже известные факты (не дублируй):\n" + ctx.existingMemories.prefix(80).map { "- " + $0 }.joined(separator: "\n") + "\n\n"
            }
        } else {
            s += "memories: всегда пустой массив.\n\n"
        }
        s += """
        speaker_names: заполняй, только если из разговора однозначно понятно, как зовут спикера (к нему обращаются по имени \
        или он представляется). Ключ — номер спикера минус один (Спикер 1 → "0"). Иначе пустой объект.

        """
        if !ctx.userName.trimmed.isEmpty {
            s += "Пользователя (владельца записи) зовут \(ctx.userName.trimmed).\n"
        }
        if !ctx.customInstructions.trimmed.isEmpty {
            s += "\nДополнительные пожелания пользователя:\n\(ctx.customInstructions.trimmed)\n"
        }
        return s
    }

    /// Map step for very long recordings: condense each part into detailed notes.
    private static func condense(_ c: Conversation, config: LLMConfig, chunkChars: Int) async throws -> String {
        var chunks: [String] = []
        var current = ""
        for s in c.segments {
            let line = "[\(Formatters.clock(s.start))] \(c.speakerName(s.speaker)): \(s.text)\n"
            if current.count + line.count > chunkChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line
        }
        if !current.isEmpty { chunks.append(current) }

        let system = """
        Ты делаешь подробный конспект части длинной расшифровки. Сохрани все факты, решения, договорённости, задачи, \
        имена, цифры и даты, ход обсуждения. Пиши компактно, Markdown-списком. Не добавляй ничего от себя.
        """
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let reply = try await LLMClient.complete(config, system: system, messages: [
                LLMMessage(role: "user", content: "Часть \(i + 1) из \(chunks.count):\n\n\(chunk)"),
            ])
            notes.append("### Часть \(i + 1)\n\(reply.trimmed)")
        }
        return notes.joined(separator: "\n\n")
    }

    private static func parse(_ obj: [String: Any]) -> SummaryResult {
        func str(_ k: String) -> String { (obj[k] as? String)?.trimmed ?? "" }
        func strings(_ k: String) -> [String] {
            guard let arr = obj[k] as? [Any] else { return [] }
            return arr.compactMap { item -> String? in
                if let s = item as? String { return s.trimmed }
                if let d = item as? [String: Any] {
                    return ((d["text"] as? String) ?? (d["point"] as? String) ?? (d["content"] as? String))?.trimmed
                }
                return nil
            }.filter { !$0.isEmpty }
        }
        var actions: [(text: String, due: Date?)] = []
        if let arr = obj["action_items"] as? [Any] {
            for item in arr {
                if let s = item as? String, !s.trimmed.isEmpty {
                    actions.append((s.trimmed, nil))
                } else if let d = item as? [String: Any], let t = (d["text"] as? String)?.trimmed, !t.isEmpty {
                    let due = (d["due"] as? String).flatMap { Formatters.isoDay.date(from: $0) }
                    actions.append((t, due))
                }
            }
        }
        var names: [String: String] = [:]
        if let dict = obj["speaker_names"] as? [String: Any] {
            for (k, v) in dict {
                if let name = (v as? String)?.trimmed, !name.isEmpty, Int(k) != nil { names[k] = name }
            }
        }
        var emoji = str("emoji")
        if emoji.isEmpty || emoji.count > 2 { emoji = emoji.first.map { String($0) } ?? "🎙️" }
        var title = str("title")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
        return SummaryResult(title: title,
                             emoji: emoji,
                             category: str("category"),
                             overview: str("overview"),
                             keyPoints: strings("key_points"),
                             actionItems: actions,
                             memories: strings("memories"),
                             speakerNames: names)
    }
}
