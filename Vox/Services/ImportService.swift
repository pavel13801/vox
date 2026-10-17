import Foundation

/// Imports audio files (Voice Memos, Telegram voice, recordings from other apps) as new conversations.
@MainActor
enum ImportService {
    static func importAudio(from url: URL) throws -> UUID {
        let store = AppStore.shared
        let settings = AppSettings.shared
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var c = Conversation(source: .imported, startedAt: creationDate(of: url) ?? Date())
        c.templateID = settings.defaultTemplate
        let folder = store.folder(for: c.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let dest = folder.appendingPathComponent("original.\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)

        c.audioFile = dest.lastPathComponent
        c.title = url.deletingPathExtension().lastPathComponent
        c.userEditedTitle = false
        c.duration = AudioFiles.duration(of: dest)
        c.finishedAt = c.startedAt.addingTimeInterval(c.duration)
        c.needsBatchTranscription = true
        c.needsSummary = settings.autoSummarize
        c.status = .transcribing
        store.insert(c)
        ProcessingQueue.shared.enqueue(c.id)
        return c.id
    }

    private static func creationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
