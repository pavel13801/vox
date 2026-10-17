import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showDone = false
    @State private var newTask = ""
    @State private var editing: ActionItem?
    @FocusState private var addFocused: Bool

    private var items: [ActionItem] {
        let list = store.actionItems.filter { $0.done == showDone }
        if showDone {
            return list.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        }
        // Open tasks: with due date first (soonest), then newest.
        return list.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        TextField("Новая задача", text: $newTask)
                            .focused($addFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                    }
                }
                if items.isEmpty {
                    EmptyStateView(icon: showDone ? "checkmark.circle" : "checklist",
                                   title: showDone ? "Выполненных пока нет" : "Задач нет",
                                   message: showDone ? "" : "ИИ добавляет сюда задачи и договорённости из ваших записей.")
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    TaskRow(item: item, showSource: true)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.deleteTask(item.id) } label: { Label("Удалить", systemImage: "trash") }
                            Button { editing = item } label: { Label("Изменить", systemImage: "pencil") }.tint(.blue)
                        }
                }
            }
            .navigationTitle("Задачи")
            .navigationDestination(for: UUID.self) { id in ConversationDetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("", selection: $showDone) {
                        Text("Открытые").tag(false)
                        Text("Готово").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .sheet(item: $editing) { item in
                EditTextSheet(title: "Задача", initial: item.text) { text in
                    store.updateTask(item.id, text: text)
                }
            }
        }
    }

    private func add() {
        let t = newTask.trimmed
        guard !t.isEmpty else { return }
        store.addTask(ActionItem(text: t))
        newTask = ""
    }
}

struct TaskRow: View {
    let item: ActionItem
    var showSource: Bool
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation { store.toggleTask(item.id) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let due = item.dueDate {
                        Label(Formatters.dayTitle(due), systemImage: "calendar")
                            .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) && !item.done ? Color.red : Color.secondary)
                    }
                    if showSource, let cid = item.conversationID, let c = store.conversation(cid) {
                        NavigationLink(value: cid) {
                            Text("\(c.emoji) \(c.displayTitle)").lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct EditTextSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text, axis: .vertical)
                    .lineLimit(3...10)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let t = text.trimmed
                        if !t.isEmpty { onSave(t) }
                        dismiss()
                    }
                }
            }
            .onAppear { text = initial }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Memories

struct MemoriesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var newMemory = ""
    @State private var editing: MemoryItem?

    private var items: [MemoryItem] {
        let q = search.trimmed.lowercased()
        guard !q.isEmpty else { return store.memories }
        return store.memories.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        TextField("Добавить факт о себе", text: $newMemory)
                            .onSubmit {
                                let t = newMemory.trimmed
                                guard !t.isEmpty else { return }
                                store.addMemories([MemoryItem(text: t)])
                                newMemory = ""
                            }
                    }
                } footer: {
                    Text("ИИ запоминает устойчивые факты о вас из записей и использует их в чате.")
                }
                if items.isEmpty {
                    EmptyStateView(icon: "brain", title: "Память пуста", message: "Факты появятся после анализа ваших записей.")
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.text)
                        HStack {
                            Text(Formatters.shortDateTime.string(from: m.createdAt))
                            if let cid = m.conversationID, let c = store.conversation(cid) {
                                NavigationLink(value: cid) { Text("· \(c.displayTitle)").lineLimit(1) }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.deleteMemory(m.id) } label: { Label("Удалить", systemImage: "trash") }
                        Button { editing = m } label: { Label("Изменить", systemImage: "pencil") }.tint(.blue)
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск по памяти")
            .navigationTitle("Память")
            .navigationDestination(for: UUID.self) { id in ConversationDetailView(id: id) }
            .sheet(item: $editing) { m in
                EditTextSheet(title: "Факт", initial: m.text) { text in store.updateMemory(m.id, text: text) }
            }
        }
    }
}
