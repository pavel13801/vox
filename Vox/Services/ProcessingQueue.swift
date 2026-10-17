import Foundation
import UIKit
import Combine

/// Runs post-recording work one conversation at a time:
/// finalize audio → (batch) transcription → AI summary, tasks and memories.
/// State lives in the conversation flags, so work resumes after an app restart.
@MainActor
final class ProcessingQueue: ObservableObject {
    static let shared = ProcessingQueue()

    @Published private(set) var activeID: UUID?
    private var queue: [UUID] = []
    private var running = false

    func enqueue(_ id: UUID) {
        if activeID == id || queue.contains(id) { return }
        queue.append(id)
        pump()
    }

    /// Called at launch: recover crashed recordings and resume unfinished work.
    func resumePending(excluding current: UUID?) {
        let store = AppStore.shared
        for c in store.conversations where c.id != current {
            if c.status == .recording {
                recoverInterrupted(c.id)
            } else if c.status == .transcribing || c.status == .summarizing {
                enqueue(c.id)
            }
        }
    }

    func retry(_ id: UUID) {
        AppStore.shared.update(id) { c in
            c.errorMessage = nil
            if c.segments.isEmpty && c.audioFile != nil { c.needsBatchTranscription = true }
            if !c.needsBatchTranscription { c.needsSummary = true }
            c.status = c.needsBatchTranscription ? .transcribing : .summarizing
        }
        enqueue(id)
    }

    func retranscribe(_ id: UUID) {
        AppStore.shared.update(id) { c in
            c.errorMessage = nil
            c.needsBatchTranscription = true
            c.needsSummary = !c.userEditedTitle || c.overview.isEmpty
            c.status = .transcribing
        }
        enqueue(id)
    }

    func resummarize(_ id: UUID, templateID: String) {
        AppStore.shared.update(id) { c in
            c.errorMessage = nil
            c.templateID = templateID
            c.needsSummary = true
            c.status = .summarizing
        }
        enqueue(id)
    }

    private func recoverInterrupted(_ id: UUID) {
        let store = AppStore.shared
        let pcm = store.rawPCMURL(for: id)
        let folder = store.folder(for: id)
        let rate = store.conversation(id)?.sampleRate ?? 16000
        Task {
            let name: String? = await Task.detached(priority: .utility) { () -> String? in
                guard FileManager.default.fileExists(atPath: pcm.path) else { return nil }
                return try? AudioFiles.finalizeRecording(pcmURL: pcm, sampleRate: rate, folder: folder)
            }.value
            store.update(id) { c in
                if let name = name {
                    c.audioFile = name
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.doubleValue ?? 0
                    if c.duration <= 0, name.hasSuffix(".wav") { c.duration = max(0, (bytes - 44) / (rate * 2)) }
                }
                if c.audioFile != nil {
                    c.needsBatchTranscription = true
                    c.status = .transcribing
                } else {
                    c.status = c.segments.isEmpty ? .failed : .summarizing
                    c.errorMessage = c.segments.isEmpty ? "Запись прервалась, аудио не сохранилось" : nil
                }
                c.needsSummary = true
                if c.finishedAt == nil { c.finishedAt = c.startedAt.addingTimeInterval(c.duration) }
            }
            if let c = store.conversation(id), let url = store.audioURL(for: c), c.duration <= 0 {
                let d = await Task.detached { AudioFiles.duration(of: url) }.value
                store.update(id) { $0.duration = d }
            }
            if store.conversation(id)?.status != .failed { enqueue(id) }
        }
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let id = queue.removeFirst()
        activeID = id
        Task {
            beginBackgroundTime()
            await process(id)
            endBackgroundTime()
            activeID = nil
            running = false
            pump()
        }
    }

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTime() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "vox.process") {
            Task { @MainActor in ProcessingQueue.shared.endBackgroundTime() }
        }
    }

    fileprivate func endBackgroundTime() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    private func process(_ id: UUID) async {
        let store = AppStore.shared
        let settings = AppSettings.shared

        // 1. Batch transcription
        if let c = store.conversation(id), c.needsBatchTranscription {
            guard let audio = store.audioURL(for: c) else {
                store.update(id) { c in
                    c.needsBatchTranscription = false
                    if c.segments.isEmpty {
                        c.status = .failed
                        c.errorMessage = "Нет аудиофайла для расшифровки"
                    }
                }
                if store.conversation(id)?.status == .failed { return }
                return await summarizeStep(id)
            }
            store.update(id) { $0.status = .transcribing; $0.errorMessage = nil }
            let provider = settings.batchProvider
            let options = BatchTranscriber.Options(
                provider: provider,
                apiKey: settings.apiKey(provider.apiProvider),
                baseURL: settings.baseURL(provider.apiProvider),
                model: provider == .deepgram ? settings.deepgramModel : settings.effectiveBatchModel,
                language: settings.language,
                diarize: settings.diarize,
                keyterms: settings.keytermList)
            do {
                let segments = try await BatchTranscriber.transcribe(file: audio, options: options)
                store.update(id) { c in
                    // Keep the live transcript if the batch result is somehow empty.
                    if !segments.isEmpty || c.segments.isEmpty {
                        let oldNames = c.speakerNames
                        c.segments = segments
                        // Batch diarization renumbers speakers; keep names only for single-speaker results.
                        if Set(segments.map { $0.speaker }).count > 1 { c.speakerNames = [:] } else { c.speakerNames = oldNames }
                    }
                    c.needsBatchTranscription = false
                    c.liveHadGaps = false
                    if let last = segments.last, c.duration < last.end { c.duration = last.end }
                }
            } catch {
                store.update(id) { c in
                    c.status = .failed
                    c.errorMessage = error.localizedDescription
                }
                return
            }
        }
        await summarizeStep(id)
    }

    private func summarizeStep(_ id: UUID) async {
        let store = AppStore.shared
        let settings = AppSettings.shared
        guard let c = store.conversation(id) else { return }

        // 2. Empty recording?
        if !c.hasSpeech {
            if settings.deleteEmpty && c.source != .imported {
                store.delete(id)
            } else {
                store.update(id) { c in
                    c.status = .done
                    c.needsSummary = false
                    if c.title.isEmpty { c.title = "Без речи" }
                    c.emoji = "🔇"
                }
            }
            return
        }

        // 3. AI summary
        guard c.needsSummary else {
            store.update(id) { $0.status = .done }
            return
        }
        guard settings.llmConfigured else {
            // No AI configured: keep needsSummary so the user can generate it later.
            store.update(id) { $0.status = .done }
            return
        }
        store.update(id) { $0.status = .summarizing; $0.errorMessage = nil }
        let ctx = Summarizer.Context(
            userName: settings.userName,
            language: settings.summaryLanguage,
            customInstructions: settings.customInstructions,
            extractTasks: settings.extractTasks,
            extractMemories: settings.extractMemories,
            existingMemories: store.memories.map { $0.text },
            maxChars: settings.maxContextChars)
        do {
            let template = SummaryTemplate.byID(c.templateID)
            let result = try await Summarizer.summarize(c, template: template, config: settings.llmConfig, context: ctx)
            // Replace previously generated open tasks of this conversation (on re-summarize).
            store.removeTasks(forConversation: id, onlyOpen: true)
            let existingTexts = Set(store.tasks(for: id).map { $0.text.lowercased() })
            let tasks = result.actionItems
                .filter { !existingTexts.contains($0.text.lowercased()) }
                .map { ActionItem(text: $0.text, conversationID: id, dueDate: $0.due) }
            store.addTasks(tasks)
            let known = Set(store.memories.map { $0.text.lowercased() })
            let mems = result.memories
                .filter { !known.contains($0.lowercased()) }
                .map { MemoryItem(text: $0, conversationID: id) }
            store.addMemories(mems)
            store.update(id) { c in
                if !c.userEditedTitle && !result.title.isEmpty { c.title = result.title }
                c.emoji = result.emoji
                c.category = result.category
                c.overview = result.overview
                c.keyPoints = result.keyPoints
                if c.speakerNames.isEmpty && !result.speakerNames.isEmpty { c.speakerNames = result.speakerNames }
                c.needsSummary = false
                c.status = .done
                c.errorMessage = nil
            }
        } catch {
            store.update(id) { c in
                c.status = .failed
                c.errorMessage = error.localizedDescription
            }
        }
    }
}
