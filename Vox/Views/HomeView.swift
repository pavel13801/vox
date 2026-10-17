import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var device: OmiDeviceManager

    @State private var search = ""
    @State private var showImporter = false
    @State private var showLive = false
    @State private var showDevice = false
    @State private var path: [UUID] = []
    @State private var importError: String?
    @State private var starredOnly = false
    @State private var categoryFilter: String?

    private var filtered: [Conversation] {
        var list = store.conversations
        if starredOnly { list = list.filter { $0.starred } }
        if let cat = categoryFilter { list = list.filter { $0.category == cat } }
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { c in
            c.displayTitle.lowercased().contains(q)
                || c.overview.lowercased().contains(q)
                || c.keyPoints.contains { $0.lowercased().contains(q) }
                || c.plainTranscript.lowercased().contains(q)
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let items: [Conversation]
        var id: Date { day }
    }

    private var grouped: [DayGroup] {
        let cal = Calendar.current
        var dict: [Date: [Conversation]] = [:]
        for c in filtered where c.id != recorder.conversationID {
            dict[cal.startOfDay(for: c.startedAt), default: []].append(c)
        }
        return dict.keys.sorted(by: >).map { DayGroup(day: $0, items: dict[$0] ?? []) }
    }

    private var categories: [String] {
        Array(Set(store.conversations.map { $0.category }.filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if recorder.isRecording {
                    Section {
                        RecordingCard { showLive = true }
                            .listRowInsets(EdgeInsets())
                    }
                }
                if let err = recorder.lastError {
                    Section {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(err).font(.footnote)
                            Spacer()
                            Button { recorder.lastError = nil } label: { Image(systemName: "xmark").font(.caption) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if grouped.isEmpty && !recorder.isRecording && store.isLoaded {
                    Section {
                        if search.isEmpty && !starredOnly && categoryFilter == nil {
                            EmptyStateView(icon: "waveform.circle",
                                           title: "Пока нет записей",
                                           message: "Нажмите на кнопку записи внизу, подключите Omi или импортируйте аудиофайл.")
                        } else {
                            EmptyStateView(icon: "magnifyingglass", title: "Ничего не найдено", message: "Попробуйте другой запрос или сбросьте фильтр.")
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(grouped, id: \.day) { group in
                    Section(Formatters.dayTitle(group.day)) {
                        ForEach(group.items) { c in
                            NavigationLink(value: c.id) {
                                ConversationRow(conversation: c)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(c.id)
                                } label: { Label("Удалить", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    store.update(c.id) { $0.starred.toggle() }
                                } label: { Label("Избранное", systemImage: c.starred ? "star.slash" : "star") }
                                .tint(.yellow)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 110).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Поиск по записям")
            .navigationTitle("Vox")
            .navigationDestination(for: UUID.self) { id in
                ConversationDetailView(id: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showDevice = true } label: { DeviceChip() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImporter = true } label: { Label("Импорт аудио", systemImage: "square.and.arrow.down") }
                        Toggle(isOn: $starredOnly) { Label("Только избранное", systemImage: "star") }
                        if !categories.isEmpty {
                            Menu("Категория") {
                                Button("Все") { categoryFilter = nil }
                                ForEach(categories, id: \.self) { cat in
                                    Button {
                                        categoryFilter = cat
                                    } label: {
                                        if categoryFilter == cat { Label(cat, systemImage: "checkmark") } else { Text(cat) }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: (starredOnly || categoryFilter != nil) ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordControls(showLive: $showLive, showDevice: $showDevice)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var lastID: UUID?
                    for url in urls {
                        do { lastID = try ImportService.importAudio(from: url) } catch { importError = error.localizedDescription }
                    }
                    if urls.count == 1, let id = lastID { path.append(id) }
                case .failure(let e):
                    importError = e.localizedDescription
                }
            }
            .alert("Не удалось импортировать", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .sheet(isPresented: $showLive) {
                LiveSessionView()
            }
            .sheet(isPresented: $showDevice) {
                NavigationStack { DeviceView() }
            }
        }
    }
}

// MARK: - Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(conversation.emoji)
                .font(.title2)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color(.tertiarySystemFill)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.starred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                HStack(spacing: 6) {
                    Text(Formatters.time.string(from: conversation.startedAt))
                    Text("·")
                    Text(Formatters.duration(conversation.duration))
                    Image(systemName: conversation.source.systemImage)
                    if !conversation.category.isEmpty {
                        Text(conversation.category)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !conversation.overview.isEmpty {
                    Text(conversation.overview.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !conversation.segments.isEmpty {
                    Text(conversation.plainTranscript)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                StatusBadge(conversation: conversation)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Device chip

struct DeviceChip: View {
    @EnvironmentObject private var device: OmiDeviceManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.circle")
            switch device.state {
            case .connected:
                if let b = device.batteryLevel {
                    Text("\(b)%").font(.caption).monospacedDigit()
                }
                Circle().fill(.green).frame(width: 7, height: 7)
            case .connecting, .reconnecting:
                Circle().fill(.orange).frame(width: 7, height: 7)
            default:
                if device.hasSavedDevice {
                    Circle().fill(.gray).frame(width: 7, height: 7)
                }
            }
        }
    }
}

// MARK: - Record controls

struct RecordControls: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var device: OmiDeviceManager
    @Binding var showLive: Bool
    @Binding var showDevice: Bool

    var body: some View {
        VStack(spacing: 10) {
            if recorder.isRecording {
                HStack(spacing: 28) {
                    Button {
                        recorder.splitNow()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "scissors").font(.title3)
                            Text("Разделить").font(.caption2)
                        }
                    }
                    .disabled(recorder.conversationID == nil)

                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        ZStack {
                            Circle().fill(Color.red).frame(width: 72, height: 72)
                            RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 26, height: 26)
                        }
                        .shadow(color: .red.opacity(0.4), radius: 10)
                    }

                    Button {
                        showLive = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "text.bubble").font(.title3)
                            Text("Текст").font(.caption2)
                        }
                    }
                }
                .foregroundStyle(.primary)
            } else {
                Picker("Источник", selection: $settings.preferredSource) {
                    Label("iPhone", systemImage: "iphone").tag(AudioSourceKind.phone)
                    Label("Omi", systemImage: "circle.circle").tag(AudioSourceKind.omi)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Button {
                    if settings.preferredSource == .omi && !device.hasSavedDevice {
                        showDevice = true
                    } else {
                        Task { await recorder.start(source: settings.preferredSource) }
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.red).frame(width: 72, height: 72)
                        Image(systemName: settings.preferredSource == .omi ? "dot.radiowaves.left.and.right" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .red.opacity(0.35), radius: 10)
                }
                .accessibilityLabel("Начать запись")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Recording card

struct RecordingCard: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var device: OmiDeviceManager
    var onOpen: () -> Void

    private var statusColor: Color {
        switch recorder.liveStatus {
        case .live: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                        .opacity(recorder.isInterrupted ? 0.3 : 1)
                    Text(recorder.waitingForDevice ? "Ожидание Omi…" : (recorder.isInterrupted ? "Пауза (прервано)" : "Идёт запись"))
                        .font(.headline)
                    Spacer()
                    Text(Formatters.clock(recorder.elapsed))
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                }
                HStack(spacing: 6) {
                    Image(systemName: recorder.source.systemImage)
                    Text(recorder.source == .omi ? (device.deviceName ?? "Omi") : "Микрофон iPhone")
                    Text("·")
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(recorder.liveStatus.label).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                LevelMeter(level: recorder.level).frame(height: 26)

                let tail = recorder.segments.suffix(2)
                if !tail.isEmpty || !recorder.interim.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(tail)) { s in
                            Text(s.text).lineLimit(2)
                        }
                        if !recorder.interim.isEmpty {
                            Text(recorder.interim).foregroundStyle(.secondary).italic().lineLimit(2)
                        }
                    }
                    .font(.subheadline)
                }
                if recorder.conversationsThisSession > 1 {
                    Text("Разговоров за сеанс: \(recorder.conversationsThisSession)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live transcript sheet

struct LiveSessionView: View {
    @EnvironmentObject private var recorder: RecordingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if recorder.segments.isEmpty && recorder.interim.isEmpty {
                            EmptyStateView(icon: "waveform",
                                           title: recorder.liveStatus == .off ? "Расшифровка после записи" : "Слушаю…",
                                           message: recorder.liveStatus == .off
                                               ? "В настройках выбран режим «После записи» — текст появится, когда запись закончится."
                                               : "Текст появится, как только кто-нибудь заговорит.")
                        }
                        ForEach(recorder.segments) { s in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("Спикер \(s.speaker + 1)").font(.caption.bold()).foregroundStyle(SpeakerPalette.color(s.speaker))
                                    Text(Formatters.clock(s.start)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(s.text).textSelection(.enabled)
                            }
                        }
                        if !recorder.interim.isEmpty {
                            Text(recorder.interim).foregroundStyle(.secondary).italic()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: recorder.segments.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: recorder.interim) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .navigationTitle(Formatters.clock(recorder.elapsed))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { recorder.splitNow() } label: { Image(systemName: "scissors") }
                        .disabled(!recorder.isRecording)
                    Button(role: .destructive) {
                        Task {
                            await recorder.stop()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                    .disabled(!recorder.isRecording)
                }
            }
        }
    }
}
