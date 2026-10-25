import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var device: OmiDeviceManager

    @State private var share: ShareItem?
    @State private var exportError: String?
    @State private var confirmDeleteAll = false
    @State private var storageText = "…"
    @State private var sttTest: TestResult?
    @State private var sttTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    TextField("Как вас зовут", text: $settings.userName)
                        .textContentType(.givenName)
                }

                Section {
                    ForEach(settings.providerIDs, id: \.self) { id in
                        NavigationLink {
                            ProviderDetailView(id: id)
                        } label: {
                            ProviderRow(id: id)
                        }
                    }
                    NavigationLink {
                        AddProviderView()
                    } label: {
                        Label("Добавить любой другой ИИ", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Ключи и провайдеры")
                } footer: {
                    Text("Ключи хранятся только на этом iPhone (в Keychain) и отправляются напрямую провайдерам. У каждого можно сохранить несколько ключей — если один упрётся в лимит, Vox сам переключится на следующий.")
                }

                Section {
                    Picker("Провайдер", selection: $settings.llmProvider) {
                        ForEach(settings.llmProviderIDs, id: \.self) { id in
                            Text(settings.title(id) + (settings.hasKey(id) ? "" : " — нет ключа")).tag(id)
                        }
                    }
                    ModelField(provider: settings.llmProvider)
                    Toggle("Автоматическая сводка", isOn: $settings.autoSummarize)
                    Picker("Язык сводки", selection: $settings.summaryLanguage) {
                        ForEach(SummaryLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Шаблон по умолчанию", selection: $settings.defaultTemplate) {
                        ForEach(SummaryTemplate.all) { Text($0.title).tag($0.id) }
                    }
                    Toggle("Извлекать задачи", isOn: $settings.extractTasks)
                    Toggle("Запоминать факты обо мне", isOn: $settings.extractMemories)
                    Picker("Объём контекста", selection: $settings.maxContextChars) {
                        Text("Малый (~100 тыс. символов)").tag(100_000)
                        Text("Средний (~300 тыс.)").tag(300_000)
                        Text("Большой (~800 тыс.)").tag(800_000)
                        Text("Огромный (~2 млн, Gemini)").tag(2_000_000)
                    }
                    NavigationLink("Свои инструкции для ИИ") { InstructionsView() }
                } header: {
                    Text("ИИ-анализ и чат")
                } footer: {
                    Text("Сводка, задачи, память и чат. Бесплатно: Google Gemini (ключ в AI Studio) или Groq. Длинные записи обрабатываются по частям.")
                }

                Section {
                    Picker("Режим", selection: $settings.transcriptionMode) {
                        ForEach(TranscriptionMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Язык", selection: $settings.language) {
                        ForEach(LanguageOption.all) { Text($0.title).tag($0.code) }
                    }
                    Picker("Модель Deepgram", selection: $settings.deepgramModel) {
                        Text("Nova-3 (лучшая)").tag("nova-3")
                        Text("Nova-2").tag("nova-2")
                        if settings.deepgramModel != "nova-3" && settings.deepgramModel != "nova-2" {
                            Text(settings.deepgramModel).tag(settings.deepgramModel)
                        }
                    }
                    Toggle("Разделять по спикерам", isOn: $settings.diarize)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ключевые слова").font(.subheadline)
                        TextField("Имена, термины, названия — через запятую", text: $settings.keyterms, axis: .vertical)
                            .lineLimit(1...4)
                            .font(.callout)
                    }
                } header: {
                    Text("Распознавание речи")
                } footer: {
                    Text("Live-текст во время записи умеет только Deepgram. В режиме «После записи» файл расшифровывает сервис ниже — любой, в том числе Gemini.")
                }

                Section {
                    Picker("Сервис", selection: $settings.batchProvider) {
                        ForEach(settings.sttProviderIDs, id: \.self) { id in
                            Text(sttLabel(id)).tag(id)
                        }
                    }
                    if settings.batchProvider != "deepgram" {
                        STTOptions(provider: settings.batchProvider)
                        Button {
                            testSTT()
                        } label: {
                            HStack {
                                Label("Проверить расшифровку", systemImage: "waveform.badge.magnifyingglass")
                                if sttTesting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(sttTesting)
                        if let r = sttTest { TestResultView(result: r) }
                    }
                    Toggle("Всегда перерасшифровывать после записи", isOn: $settings.alwaysRetranscribe)
                } header: {
                    Text("Расшифровка файла")
                } footer: {
                    Text("Для режима «После записи», импорта, «Расшифровать заново» и автоматически — если во время live-записи пропадала связь. Gemini и другие ИИ-модели различают спикеров, но время реплик приблизительное. Groq Whisper бесплатен, но без спикеров.")
                }

                Section {
                    TextField("https://vox-proxy.имя.workers.dev", text: $settings.proxyURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    NavigationLink("Как сделать свой прокси (3 минуты)") { ProxyHelpView() }
                } header: {
                    Text("Прокси (обход блокировок)")
                } footer: {
                    Text(proxyFooter)
                }

                Section {
                    Picker("Делить на разговоры", selection: $settings.autoSplitMinutes) {
                        Text("Нет — одна запись").tag(0)
                        Text("После 1 мин тишины").tag(1)
                        Text("После 2 мин тишины").tag(2)
                        Text("После 5 мин тишины").tag(5)
                        Text("После 10 мин тишины").tag(10)
                        Text("После 15 мин тишины").tag(15)
                        Text("После 30 мин тишины").tag(30)
                        Text("После 60 мин тишины").tag(60)
                    }
                    Toggle("Удалять записи без речи", isOn: $settings.deleteEmpty)
                    VStack(alignment: .leading) {
                        Text("Чувствительность к голосу (без live): \(Int((0.05 - settings.vadThreshold) / 0.045 * 100))%")
                            .font(.subheadline)
                        Slider(value: $settings.vadThreshold, in: 0.005...0.05)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                } header: {
                    Text("Запись")
                } footer: {
                    Text("Режим «весь день»: включите деление по тишине — Vox будет сам начинать новый разговор после паузы, как Omi. Запись продолжается при заблокированном экране.")
                }

                Section {
                    NavigationLink {
                        DeviceView()
                    } label: {
                        HStack {
                            Label("Устройство Omi", systemImage: "circle.circle")
                            Spacer()
                            Text(deviceSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Начинать запись при подключении", isOn: $settings.omiAutoRecord)
                    Toggle("Не засыпать в фоне", isOn: $settings.backgroundKeepAlive)
                } header: {
                    Text("Omi")
                } footer: {
                    Text("«Не засыпать в фоне» проигрывает тишину, чтобы iOS не останавливала приложение, пока звук идёт с кулона.")
                }

                Section {
                    HStack {
                        Text("Записей")
                        Spacer()
                        Text("\(store.conversations.count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Занято")
                        Spacer()
                        Text(storageText).foregroundStyle(.secondary)
                    }
                    Button {
                        do {
                            share = ShareItem(items: [try store.exportArchive()])
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: { Label("Экспорт всех данных (.zip)", systemImage: "archivebox") }
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label("Удалить все данные", systemImage: "trash")
                    }
                } header: {
                    Text("Данные")
                } footer: {
                    Text("Все записи также видны в приложении «Файлы» → На iPhone → Vox (аудио, JSON и Markdown-копия каждой записи).")
                }

                Section("Справка") {
                    NavigationLink("Установка, ключи и ошибки") { HelpView() }
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .onAppear { refreshStorage() }
            .sheet(item: $share) { item in ActivityView(items: item.items) }
            .alert("Ошибка экспорта", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
            .confirmationDialog("Удалить все записи, задачи, память и чат? Это нельзя отменить.",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Удалить всё", role: .destructive) {
                    store.deleteAll()
                    refreshStorage()
                }
            }
            .onChange(of: settings.batchProvider) { _, _ in sttTest = nil }
        }
    }

    private func sttLabel(_ id: String) -> String {
        let how: String
        switch settings.sttEngine(id) {
        case .deepgram?: how = "со спикерами"
        case .chat?: how = "ИИ-модель"
        case .whisper?: how = "Whisper"
        case nil: how = "—"
        }
        return "\(settings.title(id)) (\(how))" + (settings.hasKey(id) ? "" : " — нет ключа")
    }

    private var proxyFooter: String {
        var s = "Gemini, OpenAI и Claude не работают из России (ошибка «location is not supported»). Решения: VPN на телефоне, OpenRouter/DeepSeek или свой бесплатный прокси на Cloudflare."
        if !settings.proxyURL.trimmed.isEmpty {
            let through = settings.providerIDs.filter { settings.usesProxy($0) }.map { settings.title($0) }
            s += through.isEmpty ? " Через прокси сейчас ничего не идёт — включите в карточке провайдера." : " Через прокси идут: \(through.joined(separator: ", "))."
        }
        return s
    }

    private func testSTT() {
        sttTesting = true
        sttTest = nil
        let options = settings.batchOptions()
        Task {
            do {
                try await BatchTranscriber.verify(options: options)
                sttTest = TestResult(ok: true, text: "Расшифровка через \(options.title) (\(options.model)) работает")
            } catch {
                sttTest = TestResult(ok: false, text: error.localizedDescription)
            }
            sttTesting = false
        }
    }

    private var deviceSummary: String {
        switch device.state {
        case .connected: return device.batteryLevel.map { "подключено · \($0)%" } ?? "подключено"
        case .connecting, .reconnecting: return "подключение…"
        case .scanning: return "поиск…"
        case .unavailable(let m): return m
        case .idle: return device.hasSavedDevice ? "не в сети" : "не подключено"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func refreshStorage() {
        let store = self.store
        Task {
            let bytes = store.storageUsed()
            storageText = Formatters.bytes(bytes)
        }
    }
}

// MARK: - Small pieces

struct TestResult: Equatable {
    var ok: Bool
    var text: String
}

struct TestResultView: View {
    let result: TestResult

    var body: some View {
        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(result.ok ? Color.green : Color.red)
            .font(.footnote)
            .textSelection(.enabled)
    }
}

struct ProviderRow: View {
    let id: String
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let info = settings.provider(id)
        let keys = settings.apiKeys(id)
        let paused = keys.filter { settings.keyPause(id, $0) != nil }.count
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.title ?? id)
                Text(caps(info)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !settings.hasKey(id) {
                Text("нет ключа").font(.caption).foregroundStyle(.secondary)
            } else if keys.count > 1 {
                Text("\(keys.count - paused)/\(keys.count) ключей").font(.caption)
                    .foregroundStyle(paused == keys.count ? Color.orange : Color.green)
            } else if paused > 0 {
                Text("⏸ на паузе").font(.caption).foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func caps(_ info: ProviderInfo?) -> String {
        guard let info = info else { return "" }
        var parts: [String] = []
        if info.llm { parts.append("ИИ") }
        if settings.sttEngine(id) != nil { parts.append("расшифровка") }
        if !info.builtin { parts.append("свой") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Model fields

struct ModelField: View {
    let provider: String
    var label = "Модель"
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""
    @State private var loaded: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                TextField(settings.provider(provider)?.model ?? "модель", text: $text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(save)
                    .onChange(of: text) { _, _ in save() }
                Menu {
                    let suggested = settings.provider(provider)?.models ?? []
                    if !suggested.isEmpty {
                        Section("Рекомендуемые") {
                            ForEach(suggested, id: \.self) { m in
                                Button(m) { text = m; save() }
                            }
                        }
                    }
                    if !loaded.isEmpty {
                        Section("Доступные (\(loaded.count))") {
                            ForEach(loaded, id: \.self) { m in
                                Button(m) { text = m; save() }
                            }
                        }
                    }
                    Button {
                        load()
                    } label: { Label("Загрузить список с сервера", systemImage: "arrow.down.circle") }
                } label: {
                    if loading { ProgressView() } else { Image(systemName: "chevron.up.chevron.down") }
                }
            }
            if let e = error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { text = settings.model(provider) }
        .onChange(of: provider) { _, p in
            text = settings.model(p)
            loaded = []
            error = nil
        }
    }

    private func save() {
        if text.trimmed != settings.model(provider) { settings.setModel(text, for: provider) }
    }

    private func load() {
        loading = true
        error = nil
        var config = settings.llmConfig(for: provider)
        config.model = text
        Task {
            do {
                loaded = try await LLMClient.listModels(config)
                if loaded.isEmpty { error = "Сервер не вернул список моделей" }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// Engine + model for file transcription with a given provider.
struct STTOptions: View {
    let provider: String
    @EnvironmentObject private var settings: AppSettings
    @State private var model = ""

    var body: some View {
        let info = settings.provider(provider)
        if info?.kind == .openai {
            Picker("Способ", selection: Binding(
                get: { settings.sttEngine(provider) ?? .whisper },
                set: { settings.setSTTEngine($0, for: provider) })) {
                Text(STTEngine.whisper.title).tag(STTEngine.whisper)
                Text(STTEngine.chat.title).tag(STTEngine.chat)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Модель расшифровки")
                TextField(settings.sttModel(provider), text: $model)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: model) { _, v in settings.setSTTModel(v, for: provider) }
                let suggestions = sttSuggestions(info)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { m in Button(m) { model = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                }
            }
            Text("Сейчас: \(settings.sttModel(provider))" + (settings.sttEngine(provider) == .chat ? " · нужна модель, которая понимает звук (например, gemini-3.8-flash)" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model = settings.sttModelOverride(provider) }
        .onChange(of: provider) { _, p in model = settings.sttModelOverride(p) }
    }

    private func sttSuggestions(_ info: ProviderInfo?) -> [String] {
        guard let info = info else { return [] }
        var list = info.sttModels
        if settings.sttEngine(provider) == .chat { list += info.models }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

// MARK: - Provider card (keys, URL, model)

private struct KeyDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

struct ProviderDetailView: View {
    let id: String
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [KeyDraft] = []
    @State private var revealed: Set<UUID> = []
    @State private var results: [String: TestResult] = [:]
    @State private var summary: TestResult?
    @State private var testing = false
    @State private var sttResult: TestResult?
    @State private var sttTesting = false
    @State private var baseOverride = ""
    @State private var confirmRemove = false

    private var info: ProviderInfo? { settings.provider(id) }

    var body: some View {
        Form {
            if let info = info {
                if !info.builtin { customSection }
                keysSection(info)
                if info.builtin && info.kind != .deepgram {
                    Section {
                        TextField(info.base, text: $baseOverride)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout)
                    } header: {
                        Text("Адрес API")
                    } footer: {
                        Text("Оставьте пустым, чтобы использовать адрес по умолчанию.")
                    }
                }
                if info.llm {
                    Section("Модель для ИИ и чата") { ModelField(provider: id) }
                }
                if info.builtin && info.kind == .openai && settings.sttEngine(id) != nil {
                    Section("Расшифровка файлов") { STTOptions(provider: id) }
                }
                if !settings.proxyURL.trimmed.isEmpty {
                    Section {
                        Toggle("Через прокси", isOn: Binding(get: { settings.usesProxy(id) }, set: { settings.setUsesProxy($0, for: id) }))
                    } footer: {
                        Text(settings.proxyURL)
                    }
                }
                actionsSection(info)
            }
        }
        .navigationTitle(info?.title ?? "Провайдер")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let keys = settings.apiKeys(id)
            drafts = (keys.isEmpty ? [""] : keys).map { KeyDraft(value: $0) }
            baseOverride = settings.baseURLOverride(id)
        }
        .onDisappear { save() }
        .confirmationDialog("Удалить этого провайдера и его ключи?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                settings.removeCustomProvider(id)
                dismiss()
            }
        }
    }

    // Custom provider fields
    @ViewBuilder
    private var customSection: some View {
        if let c = settings.customProviders.first(where: { $0.id == id }) {
            Section {
                TextField("Название", text: Binding(get: { c.title }, set: { v in settings.updateCustomProvider(id) { $0.title = v } }))
                Picker("Тип API", selection: Binding(get: { c.kind }, set: { v in settings.updateCustomProvider(id) { $0.kind = v } })) {
                    Text("OpenAI-совместимый").tag(ProviderKind.openai)
                    Text("Anthropic-совместимый").tag(ProviderKind.anthropic)
                }
                TextField("https://api.example.com/v1", text: Binding(get: { c.base }, set: { v in settings.updateCustomProvider(id) { $0.base = v.trimmed } }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if c.kind == .openai {
                    Picker("Расшифровка аудио", selection: Binding(get: { c.stt }, set: { v in settings.updateCustomProvider(id) { $0.stt = v } })) {
                        Text("Не использовать").tag(STTEngine?.none)
                        Text(STTEngine.whisper.title).tag(STTEngine?.some(.whisper))
                        Text(STTEngine.chat.title).tag(STTEngine?.some(.chat))
                    }
                    if c.stt != nil {
                        TextField("Модель расшифровки", text: Binding(get: { c.sttModel }, set: { v in settings.updateCustomProvider(id) { $0.sttModel = v.trimmed } }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Свой провайдер")
            } footer: {
                Text("Адрес — это base URL API, обычно заканчивается на /v1. Подойдёт любой сервис с OpenAI- или Anthropic-совместимым API.")
            }
        }
    }

    private func keysSection(_ info: ProviderInfo) -> some View {
        Section {
            ForEach($drafts) { $draft in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ключ \((drafts.firstIndex(where: { $0.id == draft.id }) ?? 0) + 1)").font(.subheadline.bold())
                        Spacer()
                        keyBadge(draft.value)
                    }
                    HStack(spacing: 10) {
                        Group {
                            if revealed.contains(draft.id) {
                                TextField("Вставьте ключ", text: $draft.value)
                            } else {
                                SecureField("Вставьте ключ", text: $draft.value)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.callout, design: .monospaced))
                        Button {
                            if let s = UIPasteboard.general.string { draft.value = s.trimmed }
                        } label: { Image(systemName: "doc.on.clipboard") }
                        Button {
                            if revealed.contains(draft.id) { revealed.remove(draft.id) } else { revealed.insert(draft.id) }
                        } label: { Image(systemName: revealed.contains(draft.id) ? "eye.slash" : "eye") }
                        Button(role: .destructive) {
                            remove(draft.id)
                        } label: { Image(systemName: "xmark.circle") }
                    }
                    .buttonStyle(.borderless)
                    if let r = results[draft.value.trimmed], !draft.value.trimmed.isEmpty {
                        TestResultView(result: r)
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                drafts.append(KeyDraft(value: ""))
            } label: { Label("Ещё ключ (другой аккаунт)", systemImage: "plus") }
            if let url = URL(string: info.keyURL), !info.keyURL.isEmpty {
                Link(destination: url) { Label("Получить ключ", systemImage: "safari") }
            }
        } header: {
            Text(info.builtin ? "API-ключи" : "API-ключи (если нужны)")
        } footer: {
            Text("Можно добавить ключи с нескольких аккаунтов. Когда один упрётся в лимит (у Gemini — поминутный или дневной), закончатся деньги или ключ не примут, Vox сам переключится на следующий и поставит этот на паузу до сброса лимита. \(info.hint)")
        }
    }

    @ViewBuilder
    private func keyBadge(_ raw: String) -> some View {
        let key = raw.trimmed
        if key.isEmpty {
            EmptyView()
        } else if let p = settings.keyPause(id, key) {
            Text("⏸ \(p.reason) · до \(Calendar.current.isDateInToday(p.until) ? "" : "завтра ")\(Formatters.time.string(from: p.until))")
                .font(.caption2).foregroundStyle(.orange)
        } else if settings.apiKeys(id).contains(key) {
            if settings.apiKey(id) == key {
                Text("● используется").font(.caption2).foregroundStyle(.green)
            } else {
                Text("запасной").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("не сохранён").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func actionsSection(_ info: ProviderInfo) -> some View {
        Section {
            Button {
                saveAndTest()
            } label: {
                HStack {
                    Text("Сохранить и проверить ключи")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing)
            if let s = summary { TestResultView(result: s) }

            if settings.sttEngine(id) != nil && info.kind != .deepgram {
                Button {
                    testSTT()
                } label: {
                    HStack {
                        Label("Проверить расшифровку", systemImage: "waveform")
                        if sttTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(sttTesting)
                if let r = sttResult { TestResultView(result: r) }
            }
            if info.llm {
                Button(settings.llmProvider == id ? "✓ Используется для ИИ и чата" : "Использовать для ИИ и чата") {
                    settings.llmProvider = id
                }
                .disabled(settings.llmProvider == id)
            }
            if settings.sttEngine(id) != nil {
                Button(settings.batchProvider == id ? "✓ Используется для расшифровки файлов" : "Использовать для расшифровки файлов") {
                    settings.batchProvider = id
                }
                .disabled(settings.batchProvider == id)
            }
            if !info.builtin {
                Button("Удалить провайдера", role: .destructive) { confirmRemove = true }
            }
        }
    }

    // MARK: Actions

    private func remove(_ draftID: UUID) {
        drafts.removeAll { $0.id == draftID }
        if drafts.isEmpty { drafts = [KeyDraft(value: "")] }
        settings.setAPIKeys(drafts.map { $0.value }, for: id)
    }

    private func save() {
        settings.setAPIKeys(drafts.map { $0.value }, for: id)
        if let info = info, info.builtin, info.kind != .deepgram, baseOverride.trimmed != settings.baseURLOverride(id).trimmed {
            settings.setBaseURL(baseOverride, for: id)
        }
    }

    private func saveAndTest() {
        save()
        guard let info = info else { return }
        testing = true
        summary = nil
        results = [:]
        let keys = settings.apiKeys(id)
        let targets = keys.isEmpty && !info.builtin ? [""] : keys
        let providerID = id
        let appSettings = settings
        Task {
            var ok = 0
            for key in targets {
                do {
                    if info.kind == .deepgram {
                        try await BatchTranscriber.verifyDeepgram(key: key, baseURL: appSettings.route(providerID, appSettings.baseURL(providerID)))
                        results[key] = TestResult(ok: true, text: "работает")
                    } else if info.llm {
                        let cfg = appSettings.llmConfig(for: providerID, fixedKey: key)
                        let r = try await LLMClient.complete(cfg, system: "Отвечай очень кратко.", messages: [LLMMessage(role: "user", content: "Скажи «работает» одним словом.")])
                        results[key] = TestResult(ok: true, text: "работает (\(cfg.model): \(r.trimmed.prefix(40)))")
                    } else {
                        results[key] = TestResult(ok: true, text: "сохранён")
                    }
                    appSettings.clearPause(providerID, key)
                    ok += 1
                } catch {
                    results[key] = TestResult(ok: false, text: error.localizedDescription)
                }
            }
            if targets.isEmpty {
                summary = TestResult(ok: false, text: "Добавьте хотя бы один ключ")
            } else if ok == targets.count {
                summary = TestResult(ok: true, text: targets.count > 1 ? "Все ключи работают (\(ok))" : "Ключ работает")
            } else {
                summary = TestResult(ok: ok > 0, text: "Работают \(ok) из \(targets.count)")
            }
            if ok > 0 && info.llm && !appSettings.hasKey(appSettings.llmProvider) { appSettings.llmProvider = providerID }
            testing = false
        }
    }

    private func testSTT() {
        save()
        sttTesting = true
        sttResult = nil
        let options = settings.batchOptions(for: id)
        Task {
            do {
                try await BatchTranscriber.verify(options: options)
                sttResult = TestResult(ok: true, text: "Расшифровка через \(options.title) (\(options.model)) работает")
            } catch {
                sttResult = TestResult(ok: false, text: error.localizedDescription)
            }
            sttTesting = false
        }
    }
}

// MARK: - Add provider

struct AddProviderView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var created: String?

    var body: some View {
        List {
            Section {
                ForEach(Providers.presets) { p in
                    Button {
                        created = settings.addCustomProvider(p)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).foregroundStyle(.primary)
                            Text(p.base.isEmpty ? "свой адрес" : p.base).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Подходит любой сервис с OpenAI-совместимым API (так устроено большинство нейросетей) или с API как у Anthropic. Выберите шаблон — адрес подставится сам, останется вставить ключ.")
            }
        }
        .navigationTitle("Добавить провайдера")
        .navigationDestination(item: $created) { id in
            ProviderDetailView(id: id)
        }
    }
}

// MARK: - Instructions

struct InstructionsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Например: пиши кратко, выделяй сроки и суммы; меня интересуют решения по проекту X…",
                          text: $settings.customInstructions, axis: .vertical)
                    .lineLimit(5...20)
            } footer: {
                Text("Добавляется к каждому запросу на сводку.")
            }
        }
        .navigationTitle("Инструкции")
    }
}

// MARK: - Proxy help

struct ProxyHelpView: View {
    @State private var code = ""
    @State private var loadError: String?
    @State private var copied = false

    private static let codeURL = URL(string: "https://raw.githubusercontent.com/pavel13801/vox/main/web/proxy-worker.js")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MarkdownText(text: """
                Бесплатный прокси на Cloudflare пропускает запросы к Gemini, OpenAI, Claude и другим ИИ через серверы Cloudflare — так блокировка по стране не срабатывает. Ключи через него только проходят и нигде не сохраняются.

                1. Зарегистрируйтесь на **dash.cloudflare.com** (бесплатно, карта не нужна).
                2. Слева **Workers & Pages** → **Create** → **Create Worker** → назовите, например, `vox-proxy` → **Deploy**.
                3. Нажмите **Edit code**, удалите всё и вставьте код ниже (кнопка «Скопировать») → **Deploy**.
                4. Скопируйте адрес воркера (вида `https://vox-proxy.имя.workers.dev`) и вставьте в Vox: **Настройки → Прокси**.
                5. Готово: Gemini, OpenAI и Claude автоматически пойдут через прокси. Для других провайдеров включите «Через прокси» в их карточке.
                """)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать код прокси", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
                if let e = loadError {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
                Text(code.isEmpty ? "Загрузка кода…" : code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
            .padding()
        }
        .navigationTitle("Свой прокси")
        .task {
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.codeURL)
                code = String(data: data, encoding: .utf8) ?? ""
            } catch {
                loadError = "Не удалось загрузить код (нужен интернет). Его также можно открыть на github.com/pavel13801/vox → web/proxy-worker.js"
            }
        }
    }
}

// MARK: - Help

struct HelpView: View {
    var body: some View {
        ScrollView {
            MarkdownText(text: """
            ## Почему приложение «слетает»
            Приложения, подписанные бесплатным Apple ID, работают 7 дней. Затем подпись нужно обновить — данные при этом **не теряются**.

            ## Как не переустанавливать каждую неделю
            - **SideStore** (ставится через iLoader) обновляет подпись прямо на iPhone, без компьютера. Откройте SideStore → My Apps → Refresh All, когда включён LocalDevVPN.
            - Автоматизируйте: приложение «Команды» → Автоматизация → «Время суток» (например, каждый день в 10:00) → действие SideStore «Refresh All». Тогда Vox не истечёт никогда.
            - Платный аккаунт разработчика Apple ($99/год) — подпись на 1 год.

            ## Какие ключи нужны
            - Для **расшифровки** подойдёт любой вариант: **Deepgram** (лучший, со спикерами и live-текстом), **Gemini**, **Groq Whisper** (бесплатно), OpenAI, OpenRouter или свой сервер.
            - Для **сводок и чата** — любая нейросеть: Gemini, OpenAI, Claude, Groq, DeepSeek, OpenRouter, Mistral, Grok, Qwen и любые другие (Настройки → Добавить любой другой ИИ).
            - У каждого провайдера можно сохранить **несколько ключей** с разных аккаунтов: если один упрётся в лимит, Vox сам переключится на следующий.

            ## Ошибка 400 / «location is not supported»
            Google (Gemini), OpenAI и Anthropic не обслуживают Россию. Варианты: VPN на телефоне, **OpenRouter** или **DeepSeek** (работают из России) или свой бесплатный прокси (Настройки → Прокси).
            Если пишет «ключ не подходит» — скопируйте ключ заново целиком (у Gemini он начинается с «AIza»).

            ## Обновление Vox
            Новая сборка появляется в GitHub → Releases. Установите её поверх старой через SideStore — все записи сохранятся.

            ## Фоновая запись
            Запись с микрофона продолжается при заблокированном экране. Не закрывайте Vox свайпом из переключателя приложений — iOS остановит запись. Аудио пишется на диск сразу, так что даже при сбое запись восстановится при следующем запуске.
            """)
            .padding()
        }
        .navigationTitle("Справка")
    }
}
