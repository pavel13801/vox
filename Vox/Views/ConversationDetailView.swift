import SwiftUI
import UIKit

struct ConversationDetailView: View {
    let id: UUID

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var processing: ProcessingQueue
    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = AudioPlayerModel()
    @State private var tab = 0
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showSpeakers = false
    @State private var showChat = false
    @State private var share: ShareItem?
    @State private var confirmDelete = false
    @State private var newTask = ""
    @State private var copied = false

    private var conversation: Conversation? { store.conversation(id) }

    var body: some View {
        Group {
            if let c = conversation {
                content(c)
            } else {
                EmptyStateView(icon: "trash", title: "Запись удалена", message: "")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadAudio() }
        .onChange(of: conversation?.audioFile) { _, _ in loadAudio() }
        .onDisappear { player.stop() }
    }

    private func loadAudio() {
        if let c = conversation, let url = store.audioURL(for: c) { player.load(url) }
    }

    @ViewBuilder
    private func content(_ c: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(c)
                statusBanner(c)
                if store.audioURL(for: c) != nil {
                    PlayerBar(player: player).cardStyle()
                }
                Picker("", selection: $tab) {
                    Text("Сводка").tag(0)
                    Text("Транскрипт").tag(1)
                    Text("Задачи").tag(2)
                }
                .pickerStyle(.segmented)

                switch tab {
                case 0: summary(c)
                case 1: transcript(c)
                default: tasks(c)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showChat = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .disabled(!settings.llmConfigured || c.segments.isEmpty)
                menu(c)
            }
        }
        .alert("Название", isPresented: $showRename) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                let t = renameText.trimmed
                store.update(id) { $0.title = t; $0.userEditedTitle = !t.isEmpty }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakerNamesSheet(id: id)
        }
        .sheet(isPresented: $showChat) {
            NavigationStack {
                ChatThreadView(scope: id)
                    .navigationTitle("Вопросы к записи")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $share) { item in
            ActivityView(items: item.items)
        }
        .confirmationDialog("Удалить запись вместе с аудио?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                player.stop()
                store.delete(id)
                dismiss()
            }
        }
    }

    // MARK: Header

    private func header(_ c: Conversation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(c.emoji).font(.system(size: 40))
            VStack(alignment: .leading, spacing: 4) {
                Text(c.displayTitle)
                    .font(.title3.bold())
                    .onTapGesture {
                        renameText = c.title
                        showRename = true
                    }
                HStack(spacing: 6) {
                    Text(Formatters.longDateTime.string(from: c.startedAt))
                    Text("·")
                    Text(Formatters.duration(c.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(c.source.label, systemImage: c.source.systemImage)
                    if !c.category.isEmpty { Text("· \(c.category)") }
                    Text("· \(c.wordCount) слов")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.update(id) { $0.starred.toggle() }
            } label: {
                Image(systemName: c.starred ? "star.fill" : "star").foregroundStyle(.yellow)
            }
        }
    }

    @ViewBuilder
    private func statusBanner(_ c: Conversation) -> some View {
        if c.isProcessing || processing.activeID == id {
            HStack(spacing: 10) {
                ProgressView()
                Text(c.status == .summarizing ? "ИИ анализирует запись…" : "Идёт расшифровка…" + (processing.progress[id].map { " (\($0))" } ?? "")).font(.subheadline)
                Spacer()
            }
            .cardStyle()
        } else if c.status == .failed {
            VStack(alignment: .leading, spacing: 8) {
                Label("Не удалось обработать", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold()).foregroundStyle(.orange)
                if let e = c.errorMessage { Text(e).font(.footnote).textSelection(.enabled) }
                Button("Повторить") { processing.retry(id) }
                    .buttonStyle(.borderedProminent)
            }
            .cardStyle()
        } else if c.needsSummary && c.hasSpeech && c.status == .done {
            HStack {
                Text(settings.llmConfigured ? "Сводка ещё не создана" : "Добавьте ключ ИИ в настройках, чтобы получить сводку и задачи")
                    .font(.footnote)
                Spacer()
                if settings.llmConfigured {
                    Button("Создать") { processing.resummarize(id, templateID: c.templateID) }
                        .buttonStyle(.bordered)
                }
            }
            .cardStyle()
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summary(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if c.overview.isEmpty && c.keyPoints.isEmpty {
                Text(c.segments.isEmpty ? "Пока нет текста." : "Сводки пока нет.")
                    .foregroundStyle(.secondary)
            }
            if !c.overview.isEmpty {
                MarkdownText(text: c.overview)
            }
            if !c.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ключевые моменты").font(.headline)
                    ForEach(Array(c.keyPoints.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "sparkle").font(.caption).foregroundStyle(Color.accentColor)
                            MarkdownText(text: p)
                        }
                    }
                }
            }
            let openTasks = store.tasks(for: id).filter { !$0.done }
            if !openTasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Задачи").font(.headline)
                    ForEach(openTasks) { t in
                        TaskRow(item: t, showSource: false)
                    }
                }
            }
            if settings.llmConfigured && !c.segments.isEmpty {
                Menu {
                    ForEach(SummaryTemplate.all) { t in
                        Button {
                            processing.resummarize(id, templateID: t.id)
                        } label: {
                            Label(t.title, systemImage: t.id == c.templateID ? "checkmark" : t.icon)
                        }
                    }
                } label: {
                    Label("Пересоздать сводку · \(SummaryTemplate.byID(c.templateID).title)", systemImage: "wand.and.stars")
                        .font(.subheadline)
                }
                .disabled(c.isProcessing)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcript(_ c: Conversation) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if c.segments.isEmpty {
                Text(c.isProcessing ? "Расшифровка в процессе…" : "Текста нет.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Button {
                        showSpeakers = true
                    } label: {
                        Label("Спикеры", systemImage: "person.2")
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = c.formattedTranscript(withTimestamps: false)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)

                ForEach(c.segments) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(c.speakerName(s.speaker))
                                .font(.caption.bold())
                                .foregroundStyle(SpeakerPalette.color(s.speaker))
                                .onTapGesture { showSpeakers = true }
                            Button {
                                player.play(from: s.start)
                            } label: {
                                Text(Formatters.clock(s.start)).font(.caption2).monospacedDigit()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Text(s.text)
                            .textSelection(.enabled)
                            .padding(.leading, 2)
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SpeakerPalette.color(s.speaker).opacity(0.6)).frame(width: 3)
                    }
                }
            }
        }
    }

    // MARK: Tasks

    @ViewBuilder
    private func tasks(_ c: Conversation) -> some View {
        let items = store.tasks(for: id)
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("Задач из этой записи нет.").foregroundStyle(.secondary)
            }
            ForEach(items) { t in
                TaskRow(item: t, showSource: false)
            }
            HStack {
                TextField("Новая задача", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                Button("Добавить", action: addTask).disabled(newTask.trimmed.isEmpty)
            }
        }
    }

    private func addTask() {
        let t = newTask.trimmed
        guard !t.isEmpty else { return }
        store.addTask(ActionItem(text: t, conversationID: id))
        newTask = ""
    }

    // MARK: Menu

    private func menu(_ c: Conversation) -> some View {
        Menu {
            Button {
                renameText = c.title
                showRename = true
            } label: { Label("Переименовать", systemImage: "pencil") }
            Button { showSpeakers = true } label: { Label("Имена спикеров", systemImage: "person.2") }
                .disabled(c.segments.isEmpty)
            Divider()
            Button {
                let md = c.markdown(actionItems: store.tasks(for: id))
                share = ShareItem(items: [md])
            } label: { Label("Поделиться текстом", systemImage: "square.and.arrow.up") }
            Button {
                let md = c.markdown(actionItems: store.tasks(for: id))
                let name = sanitizedFileName(c)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".md")
                try? md.write(to: url, atomically: true, encoding: .utf8)
                share = ShareItem(items: [url])
            } label: { Label("Экспорт Markdown (.md)", systemImage: "doc.richtext") }
            if let audio = store.audioURL(for: c) {
                Button {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(sanitizedFileName(c) + "." + audio.pathExtension)
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.copyItem(at: audio, to: url)
                    share = ShareItem(items: [url])
                } label: { Label("Поделиться аудио", systemImage: "waveform") }
            }
            Divider()
            if store.audioURL(for: c) != nil {
                Button {
                    processing.retranscribe(id)
                } label: { Label("Расшифровать заново (\(settings.title(settings.batchProvider)))", systemImage: "arrow.clockwise") }
                .disabled(c.isProcessing)
            }
            if settings.llmConfigured {
                Menu {
                    ForEach(SummaryTemplate.all) { t in
                        Button(t.title) { processing.resummarize(id, templateID: t.id) }
                    }
                } label: { Label("Сводка по шаблону", systemImage: "wand.and.stars") }
                .disabled(c.isProcessing || c.segments.isEmpty)
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Удалить", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func sanitizedFileName(_ c: Conversation) -> String {
        let base = Formatters.fileStamp.string(from: c.startedAt) + " " + c.displayTitle
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return base.components(separatedBy: bad).joined(separator: "-").prefix(80).description
    }
}

// MARK: - Speaker names

struct SpeakerNamesSheet: View {
    let id: UUID
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var names: [Int: String] = [:]
    @State private var mergeFrom: Int?

    var body: some View {
        NavigationStack {
            Form {
                if let c = store.conversation(id) {
                    Section {
                        ForEach(c.speakers, id: \.self) { sp in
                            HStack {
                                Circle().fill(SpeakerPalette.color(sp)).frame(width: 10, height: 10)
                                TextField("Спикер \(sp + 1)", text: Binding(
                                    get: { names[sp] ?? "" },
                                    set: { names[sp] = $0 }))
                                if !settings.userName.isEmpty {
                                    Button("Это я") { names[sp] = settings.userName }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    } header: {
                        Text("Имена")
                    } footer: {
                        Text("Пример фразы: «\(sample(c))»")
                    }
                    if c.speakers.count > 1 {
                        Section {
                            ForEach(c.speakers, id: \.self) { from in
                                Menu("Объединить «\(c.speakerName(from))» с…") {
                                    ForEach(c.speakers.filter { $0 != from }, id: \.self) { to in
                                        Button(c.speakerName(to)) { merge(from: from, into: to) }
                                    }
                                }
                            }
                        } header: {
                            Text("Ошибки разделения")
                        } footer: {
                            Text("Если один человек распознан как два спикера — объедините их.")
                        }
                    }
                }
            }
            .navigationTitle("Спикеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        store.update(id) { c in
                            var dict: [String: String] = [:]
                            for (k, v) in names where !v.trimmed.isEmpty { dict[String(k)] = v.trimmed }
                            c.speakerNames = dict
                        }
                        store.update(id) { _ in } // refresh markdown copy
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let c = store.conversation(id) {
                    var n: [Int: String] = [:]
                    for (k, v) in c.speakerNames { if let i = Int(k) { n[i] = v } }
                    names = n
                }
            }
        }
    }

    private func sample(_ c: Conversation) -> String {
        String(c.segments.first?.text.prefix(60) ?? "")
    }

    private func merge(from: Int, into: Int) {
        store.update(id) { c in
            for i in c.segments.indices where c.segments[i].speaker == from {
                c.segments[i].speaker = into
            }
            c.segments = BatchTranscriber.mergeSameSpeaker(c.segments, maxGap: 30, maxChars: 2000)
            c.speakerNames.removeValue(forKey: String(from))
        }
        names.removeValue(forKey: from)
    }
}
