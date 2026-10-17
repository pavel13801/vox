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

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль") {
                    TextField("Как вас зовут", text: $settings.userName)
                        .textContentType(.givenName)
                }

                Section {
                    NavigationLink {
                        KeysView()
                    } label: {
                        HStack {
                            Label("Ключи API", systemImage: "key.fill")
                            Spacer()
                            Text(keysSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Ключи хранятся только на этом iPhone (в Keychain). Запросы идут напрямую к провайдерам — без посредников и лимитов.")
                }

                Section {
                    Picker("Расшифровка", selection: $settings.transcriptionMode) {
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
                    Text("Live — текст появляется во время записи (Deepgram ≈ $0.46/час). «После записи» — файл расшифровывается целиком, дешевле (≈ $0.26/час) и точнее со спикерами. При $200 бесплатного кредита Deepgram это сотни часов.")
                }

                Section {
                    Picker("Сервис", selection: $settings.batchProvider) {
                        ForEach(BatchSTTProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.batchProvider != .deepgram {
                        TextField("Модель (\(settings.batchProvider.defaultModel))", text: $settings.batchModel)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("Всегда перерасшифровывать после записи", isOn: $settings.alwaysRetranscribe)
                } header: {
                    Text("Расшифровка файла")
                } footer: {
                    Text("Используется для режима «После записи», импорта, кнопки «Расшифровать заново» и автоматически — если во время live-записи пропадала связь. Groq Whisper бесплатен (до ~8 ч в день), но не различает спикеров.")
                }

                Section {
                    Picker("Провайдер", selection: $settings.llmProvider) {
                        ForEach(APIProvider.llmProviders) { p in
                            HStack {
                                Text(p.title)
                                if !settings.hasKey(p) { Text("— нет ключа") }
                            }
                            .tag(p)
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
                    NavigationLink("Свои инструкции для ИИ") {
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
                } header: {
                    Text("ИИ-анализ и чат")
                } footer: {
                    Text("Сводка, задачи, память и чат. Бесплатно: Google Gemini (ключ в AI Studio) или Groq. Длинные записи, не влезающие в контекст, обрабатываются по частям.")
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
                    NavigationLink("Установка и продление приложения") { HelpView() }
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
        }
    }

    private var keysSummary: String {
        _ = settings.keysRevision
        let n = APIProvider.allCases.filter { $0 != .custom && settings.hasKey($0) }.count
        return n == 0 ? "не заданы" : "задано: \(n)"
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

// MARK: - Model field

struct ModelField: View {
    let provider: APIProvider
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""
    @State private var loaded: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Модель")
                TextField(provider.defaultModel, text: $text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(save)
                    .onChange(of: text) { _, _ in save() }
                Menu {
                    Section("Рекомендуемые") {
                        ForEach(provider.suggestedModels, id: \.self) { m in
                            Button(m) { text = m; save() }
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
        settings.setModel(text, for: provider)
    }

    private func load() {
        loading = true
        error = nil
        let config = LLMConfig(provider: provider, baseURL: settings.baseURL(provider), apiKey: settings.apiKey(provider), model: text)
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

// MARK: - Keys

struct KeysView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(APIProvider.allCases) { p in
                    NavigationLink {
                        ProviderKeyView(provider: p)
                    } label: {
                        HStack {
                            Text(p.title)
                            Spacer()
                            if settings.hasKey(p) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("нет").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Минимум: ключ Deepgram (расшифровка) + ключ любого ИИ (сводки, чат). Один ключ Groq/OpenAI работает и для ИИ, и для Whisper.")
            }
        }
        .navigationTitle("Ключи API")
        .id(settings.keysRevision)
    }
}

struct ProviderKeyView: View {
    let provider: APIProvider
    @EnvironmentObject private var settings: AppSettings
    @State private var key = ""
    @State private var baseURL = ""
    @State private var reveal = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var testOK = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Group {
                        if reveal {
                            TextField("API-ключ", text: $key)
                        } else {
                            SecureField("API-ключ", text: $key)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.plain)
                }
                Button {
                    if let s = UIPasteboard.general.string { key = s.trimmed }
                } label: { Label("Вставить из буфера", systemImage: "doc.on.clipboard") }
                if let url = provider.keyURL {
                    Link(destination: url) { Label("Получить ключ", systemImage: "safari") }
                }
            } header: {
                Text(provider.title)
            } footer: {
                Text(provider.keyHint)
            }

            if provider != .deepgram {
                Section {
                    TextField(provider.defaultBaseURL, text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.callout)
                } header: {
                    Text("Адрес API")
                } footer: {
                    Text(provider == .custom
                         ? "Любой OpenAI-совместимый сервер: Ollama, LM Studio, vLLM, прокси. Например http://192.168.1.10:11434/v1"
                         : "Оставьте пустым, чтобы использовать адрес по умолчанию.")
                }
                Section {
                    ModelField(provider: provider)
                }
            }

            Section {
                Button {
                    save()
                    test()
                } label: {
                    HStack {
                        Text("Сохранить и проверить")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing)
                if let r = testResult {
                    Label(r, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testOK ? Color.green : Color.red)
                        .font(.footnote)
                }
                if settings.hasKey(provider) && provider != .custom {
                    Button("Удалить ключ", role: .destructive) {
                        key = ""
                        settings.setAPIKey("", for: provider)
                    }
                }
            }
        }
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            key = settings.apiKey(provider)
            let stored = UserDefaults.standard.string(forKey: "baseURL." + provider.rawValue) ?? ""
            baseURL = stored
        }
        .onDisappear { save() }
    }

    private func save() {
        if key.trimmed != settings.apiKey(provider) { settings.setAPIKey(key, for: provider) }
        if provider != .deepgram { settings.setBaseURL(baseURL, for: provider) }
    }

    private func test() {
        testing = true
        testResult = nil
        let p = provider
        let k = key.trimmed
        let config = LLMConfig(provider: p, baseURL: settings.baseURL(p), apiKey: k, model: settings.model(p))
        Task {
            do {
                if p == .deepgram {
                    try await BatchTranscriber.verifyDeepgram(key: k)
                    testResult = "Ключ Deepgram работает"
                } else {
                    let reply = try await LLMClient.complete(config, system: "Отвечай очень кратко.", messages: [LLMMessage(role: "user", content: "Скажи «работает» одним словом.")])
                    testResult = "Ответ модели \(config.model): \(reply.trimmed.prefix(60))"
                }
                testOK = true
            } catch {
                testResult = error.localizedDescription
                testOK = false
            }
            testing = false
        }
    }
}

// MARK: - Device

struct DeviceView: View {
    @EnvironmentObject private var device: OmiDeviceManager
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            if case .unavailable(let msg) = device.state {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if device.hasSavedDevice {
                Section("Моё устройство") {
                    HStack {
                        Image(systemName: "circle.circle.fill").font(.title).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(device.deviceName ?? device.savedDeviceName ?? "Omi").font(.headline)
                            Text(stateText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let b = device.batteryLevel {
                            Label("\(b)%", systemImage: batteryIcon(b)).font(.callout).monospacedDigit()
                        }
                    }
                    if device.isConnected {
                        if let codec = device.codec { row("Кодек", codec.title) }
                        if let fw = device.firmware { row("Прошивка", fw) }
                        if let model = device.model { row("Модель", model) }
                        if device.lostFrames > 0 { row("Потеряно кадров", "\(device.lostFrames)") }
                        if !recorder.isRecording {
                            Button {
                                settings.preferredSource = .omi
                                Task { await recorder.start(source: .omi) }
                            } label: { Label("Начать запись с Omi", systemImage: "record.circle") }
                        }
                    } else {
                        Button { device.reconnectSaved() } label: { Label("Переподключить", systemImage: "arrow.clockwise") }
                    }
                    Button("Отключить и забыть", role: .destructive) { device.disconnect(forget: true) }
                }
            }

            Section {
                if device.state == .scanning {
                    HStack {
                        ProgressView()
                        Text("Ищу устройства…").foregroundStyle(.secondary)
                    }
                } else {
                    Button { device.startScan() } label: { Label("Найти устройство", systemImage: "magnifyingglass") }
                }
                ForEach(device.discovered) { d in
                    Button {
                        device.connect(to: d.id)
                    } label: {
                        HStack {
                            Image(systemName: d.isOmi ? "circle.circle.fill" : "dot.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text("Сигнал \(d.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.id == device.savedDeviceID && device.isConnected {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Toggle("Показывать все Bluetooth-устройства", isOn: $device.showAllDevices)
            } header: {
                Text("Поиск")
            } footer: {
                Text("Включите Omi и держите рядом с iPhone. Если устройство подключено к официальному приложению Omi — сначала отключите его там. Vox будет сам переподключаться к кулону, как только он окажется рядом.")
            }
        }
        .navigationTitle("Omi")
        .onAppear { device.activate() }
        .onDisappear { device.stopScan() }
    }

    private var stateText: String {
        switch device.state {
        case .connected: return device.isStreaming ? "Подключено · звук идёт" : "Подключено"
        case .connecting: return "Подключение…"
        case .reconnecting: return "Ожидание устройства…"
        case .scanning: return "Поиск…"
        case .idle: return "Не в сети"
        case .unavailable(let m): return m
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
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

            ## Обновление Vox
            Новая сборка появляется в GitHub → Releases. Установите её поверх старой через SideStore (+ → выбрать .ipa) — все записи сохранятся, если bundle ID тот же.

            ## Ключи
            - Deepgram: console.deepgram.com — при регистрации дают $200 (сотни часов записи).
            - Gemini: aistudio.google.com — бесплатный лимит, хватает для сводок и чата.
            - Groq: console.groq.com — бесплатно, есть Whisper для расшифровки.

            ## Фоновая запись
            Запись с микрофона продолжается при заблокированном экране. Не закрывайте Vox свайпом из переключателя приложений — iOS остановит запись. Аудио пишется на диск сразу, так что даже при сбое запись восстановится при следующем запуске.
            """)
            .padding()
        }
        .navigationTitle("Справка")
    }
}
