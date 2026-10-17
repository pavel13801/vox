import Foundation

/// Per-conversation audio sink: writes PCM to disk, streams it to Deepgram and meters the level.
/// Thread-safe — `ingest` may be called from any thread (audio tap, Bluetooth callbacks).
final class AudioPipeline {
    let conversationID: UUID
    let sampleRate: Double
    let hasLive: Bool

    /// level 0…1, voiced flag, total seconds of audio so far. Called on an internal queue ~10×/s.
    var onMeter: ((Float, Bool, Double) -> Void)?
    var onLive: ((LiveResult) -> Void)? {
        didSet { live?.onResult = onLive }
    }
    var onLiveStatus: ((DeepgramLiveClient.Status) -> Void)? {
        didSet { live?.onStatus = onLiveStatus }
    }

    private let writer: PCMFileWriter?
    private let live: DeepgramLiveClient?
    private let q = DispatchQueue(label: "vox.pipeline", qos: .userInitiated)
    private let vadThreshold: Float
    private var samples: Int64 = 0
    private var stopped = false
    private var meterPeak: Float = 0
    private var meterSamples = 0

    init(conversationID: UUID, sampleRate: Double, pcmURL: URL, live: DeepgramLiveClient.Options?, vadThreshold: Double) {
        self.conversationID = conversationID
        self.sampleRate = sampleRate
        self.writer = try? PCMFileWriter(url: pcmURL)
        self.live = live.map { DeepgramLiveClient(options: $0) }
        self.hasLive = live != nil
        self.vadThreshold = Float(vadThreshold)
        if let w = writer { samples = w.bytesWritten / 2 }
    }

    var writerAvailable: Bool { writer != nil }

    func start() {
        live?.start()
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        q.async {
            guard !self.stopped else { return }
            self.writer?.append(data)
            self.live?.send(data)
            self.meter(data)
        }
    }

    private func meter(_ data: Data) {
        let count = data.count / 2
        guard count > 0 else { return }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            var i = 0
            // Sub-sample for speed: every 4th sample is plenty for metering.
            while i < p.count {
                let v = Double(p[i])
                sumSquares += v * v
                i += 4
            }
        }
        let n = Double((count + 3) / 4)
        let rms = Float(sqrt(sumSquares / max(1, n)) / 32768.0)
        samples += Int64(count)
        meterPeak = max(meterPeak, rms)
        meterSamples += count
        if meterSamples >= Int(sampleRate / 10) {
            let level = meterPeak
            meterPeak = 0
            meterSamples = 0
            onMeter?(level, level > vadThreshold, Double(samples) / sampleRate)
        }
    }

    /// Closes the file and finishes the live stream. Completion: (liveHadGaps, totalSeconds).
    func stop(_ completion: @escaping (Bool, Double) -> Void) {
        q.async {
            self.stopped = true
            self.writer?.close()
            let seconds = Double(self.samples) / self.sampleRate
            if let live = self.live {
                live.finish { gaps in completion(gaps, seconds) }
            } else {
                completion(false, seconds)
            }
        }
    }
}

/// Lock-protected pointer to the pipeline that currently receives audio.
final class PipelineBox {
    private let lock = NSLock()
    private var _current: AudioPipeline?

    var current: AudioPipeline? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }

    func ingest(_ data: Data) {
        current?.ingest(data)
    }
}
