import Foundation

/// Accumulates Deepgram live results into speaker-grouped segments.
struct LiveTranscript {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var interim: String = ""
    private(set) var interimSpeaker: Int?
    private(set) var lastWordEnd: Double = 0

    var isEmpty: Bool { segments.isEmpty }

    mutating func apply(_ r: LiveResult) {
        guard r.isFinal else {
            interim = r.transcript
            interimSpeaker = r.words.first?.speaker
            return
        }
        interim = ""
        interimSpeaker = nil

        if r.words.isEmpty {
            let text = r.transcript.trimmed
            guard !text.isEmpty else { return }
            append(speaker: segments.last?.speaker ?? 0, text: text, start: r.start, end: r.end)
            return
        }

        // Split the result into runs of the same speaker.
        var runSpeaker = r.words[0].speaker
        var runWords: [String] = []
        var runStart = r.words[0].start
        var runEnd = r.words[0].end
        for w in r.words {
            if w.speaker != runSpeaker {
                append(speaker: runSpeaker, text: runWords.joined(separator: " "), start: runStart, end: runEnd)
                runSpeaker = w.speaker
                runWords = []
                runStart = w.start
            }
            runWords.append(w.text)
            runEnd = w.end
        }
        append(speaker: runSpeaker, text: runWords.joined(separator: " "), start: runStart, end: runEnd)
    }

    private mutating func append(speaker: Int, text: String, start: Double, end: Double) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        lastWordEnd = max(lastWordEnd, end)
        if var last = segments.last, last.speaker == speaker, start - last.end < 20, last.text.count < 1500 {
            last.text += " " + t
            last.end = max(last.end, end)
            segments[segments.count - 1] = last
        } else {
            segments.append(TranscriptSegment(speaker: speaker, text: t, start: start, end: end))
        }
    }
}
