import Foundation
import Combine

/// File-based persistence: every conversation lives in its own folder inside Documents
/// (visible in the Files app), next to its audio and a Markdown copy of the transcript.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var actionItems: [ActionItem] = []
    @Published private(set) var memories: [MemoryItem] = []
    @Published private(set) var chatMessages: [ChatMessage] = []
    @Published private(set) var isLoaded = false

    let documents: URL
    let conversationsDir: URL
    private let ioQueue = DispatchQueue(label: "vox.store.io", qos: .utility)

    nonisolated static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    nonisolated static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private let encoder = AppStore.makeEncoder()

    private init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        conversationsDir = documents.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
    }

    // MARK: Loading

    func load() async {
        let convDir = conversationsDir
        let docs = documents
        let result = await Task.detached(priority: .userInitiated) { () -> ([Conversation], [ActionItem], [MemoryItem], [ChatMessage]) in
            let fm = FileManager.default
            let dec = AppStore.makeDecoder()
            var convs: [Conversation] = []
            if let dirs = try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) {
                for dir in dirs {
                    let file = dir.appendingPathComponent("conversation.json")
                    guard let data = try? Data(contentsOf: file) else { continue }
                    if let c = try? dec.decode(Conversation.self, from: data) {
                        convs.append(c)
                    }
                }
            }
            convs.sort { $0.startedAt > $1.startedAt }
            func loadArray<T: Decodable>(_ name: String, _ type: T.Type) -> [T] {
                guard let data = try? Data(contentsOf: docs.appendingPathComponent(name)) else { return [] }
                return (try? dec.decode([T].self, from: data)) ?? []
            }
            let tasks = loadArray("tasks.json", ActionItem.self)
            let mems = loadArray("memories.json", MemoryItem.self)
            let chat = loadArray("chat.json", ChatMessage.self)
            return (convs, tasks, mems, chat)
        }.value
        conversations = result.0
        actionItems = result.1
        memories = result.2
        chatMessages = result.3
        isLoaded = true
    }

    // MARK: Paths

    func folder(for id: UUID) -> URL {
        conversationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(for c: Conversation) -> URL? {
        guard let name = c.audioFile else { return nil }
        let url = folder(for: c.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func rawPCMURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("recording.pcm")
    }

    func markdownURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("transcript.md")
    }

    // MARK: Conversations

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func insert(_ c: Conversation) {
        try? FileManager.default.createDirectory(at: folder(for: c.id), withIntermediateDirectories: true)
        conversations.insert(c, at: 0)
        conversations.sort { $0.startedAt > $1.startedAt }
        persist(c)
    }

    func update(_ id: UUID, persist shouldPersist: Bool = true, _ mutate: (inout Conversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var c = conversations[idx]
        mutate(&c)
        conversations[idx] = c
        if shouldPersist { persist(c) }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        let dir = folder(for: id)
        ioQueue.async { try? FileManager.default.removeItem(at: dir) }
        var changed = false
        for i in actionItems.indices where actionItems[i].conversationID == id {
            actionItems[i].conversationID = nil
            changed = true
        }
        if changed { saveTasks() }
    }

    private func persist(_ c: Conversation) {
        guard let data = try? encoder.encode(c) else { return }
        let dir = folder(for: c.id)
        let md = c.status == .recording ? nil : c.markdown(actionItems: tasks(for: c.id))
        ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("conversation.json"), options: .atomic)
            if let md = md {
                try? md.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Tasks

    func tasks(for conversationID: UUID) -> [ActionItem] {
        actionItems.filter { $0.conversationID == conversationID }
    }

    func addTask(_ item: ActionItem) {
        actionItems.insert(item, at: 0)
        saveTasks()
    }

    func addTasks(_ items: [ActionItem]) {
        guard !items.isEmpty else { return }
        actionItems.insert(contentsOf: items, at: 0)
        saveTasks()
    }

    func toggleTask(_ id: UUID) {
        guard let i = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[i].done.toggle()
        actionItems[i].completedAt = actionItems[i].done ? Date() : nil
        saveTasks()
    }

    func updateTask(_ id: UUID, text: String) {
        guard let i = actionItems.firstIndex(where: { $0.id == id }) else { return }
        actionItems[i].text = text
        saveTasks()
    }

    func deleteTask(_ id: UUID) {
        actionItems.removeAll { $0.id == id }
        saveTasks()
    }

    func removeTasks(forConversation id: UUID, onlyOpen: Bool) {
        actionItems.removeAll { $0.conversationID == id && (!onlyOpen || !$0.done) }
        saveTasks()
    }

    private func saveTasks() { writeArray(actionItems, "tasks.json") }

    // MARK: Memories

    func addMemories(_ items: [MemoryItem]) {
        guard !items.isEmpty else { return }
        memories.insert(contentsOf: items, at: 0)
        saveMemories()
    }

    func updateMemory(_ id: UUID, text: String) {
        guard let i = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[i].text = text
        saveMemories()
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
    }

    private func saveMemories() { writeArray(memories, "memories.json") }

    // MARK: Chat

    func appendChat(_ m: ChatMessage) {
        chatMessages.append(m)
        saveChat()
    }

    func updateChat(_ id: UUID, text: String, isError: Bool = false, persist: Bool = true) {
        guard let i = chatMessages.firstIndex(where: { $0.id == id }) else { return }
        chatMessages[i].text = text
        chatMessages[i].isError = isError
        if persist { saveChat() }
    }

    func clearChat() {
        chatMessages.removeAll()
        saveChat()
    }

    private func saveChat() { writeArray(chatMessages, "chat.json") }

    // MARK: Helpers

    private func writeArray<T: Encodable>(_ items: [T], _ name: String) {
        guard let data = try? encoder.encode(items) else { return }
        let url = documents.appendingPathComponent(name)
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    func storageUsed() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let en = fm.enumerator(at: documents, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Zips the whole Documents folder for sharing (uses the system zipper of NSFileCoordinator).
    func exportArchive() throws -> URL {
        var resultURL: URL?
        var coordError: NSError?
        var innerError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: documents, options: [.forUploading], error: &coordError) { zipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Vox-backup-\(Formatters.fileStamp.string(from: Date())).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
                resultURL = dest
            } catch {
                innerError = error
            }
        }
        if let e = coordError { throw e }
        if let e = innerError { throw e }
        guard let url = resultURL else { throw VoxError.message("Не удалось создать архив") }
        return url
    }

    func deleteAll() {
        let ids = conversations.map { $0.id }
        for id in ids { delete(id) }
        actionItems.removeAll(); saveTasks()
        memories.removeAll(); saveMemories()
        chatMessages.removeAll(); saveChat()
    }
}

enum VoxError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
