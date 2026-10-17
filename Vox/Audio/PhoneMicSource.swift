import Foundation
import AVFoundation

/// Captures the iPhone microphone and delivers 16 kHz mono Int16 PCM chunks.
/// Keeps running with the screen locked thanks to the `audio` background mode.
final class PhoneMicSource {
    var onPCM: ((Data) -> Void)?
    var onInterruption: ((Bool) -> Void)?

    let sampleRate: Double = 16000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()

    deinit {
        stop()
    }

    func start() throws {
        try AudioSessionManager.activateForRecording()
        try startEngine()
        running = true
        addObservers()
    }

    func stop() {
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw VoxError.message("Микрофон недоступен")
        }
        lock.lock()
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        addEngineObserver()
        do {
            try AudioSessionManager.activateForRecording()
            try startEngine()
        } catch {
            // Try again a bit later (e.g. right after a phone call ends).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.running, !self.engine.isRunning else { return }
                self.restart()
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let conv = converter
        lock.unlock()
        guard let converter = conv, buffer.frameLength > 0 else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 256)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        onPCM?(data)
    }

    // MARK: Notifications

    private var engineObserver: NSObjectProtocol?

    private func addEngineObserver() {
        if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    private func addObservers() {
        let nc = NotificationCenter.default
        addEngineObserver()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.onInterruption?(true)
            case .ended:
                self.onInterruption?(false)
                self.restart()
            @unknown default:
                break
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }
}

enum AudioSessionManager {
    static func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPreferredSampleRate(48000)
        try session.setActive(true, options: [])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord && RecordingActivity.isActive { return }
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true, options: [])
    }

    static func activateForBackgroundKeepAlive() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])
    }
}

/// Thread-safe flag other components can read to know whether a recording is running.
enum RecordingActivity {
    private static let lock = NSLock()
    private static var _active = false
    static var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
}

/// Plays inaudible silence so iOS keeps the app alive in the background while audio
/// comes from the Omi device over Bluetooth (no microphone use).
final class SilentKeepAlive {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard engine == nil else { return }
        do {
            try AudioSessionManager.activateForBackgroundKeepAlive()
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else { return }
            buffer.frameLength = 44100
            if let ch = buffer.floatChannelData {
                memset(ch[0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            self.engine = engine
            self.player = player
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.restart()
            }
        } catch {
            engine = nil
            player = nil
        }
    }

    private func restart() {
        stop()
        start()
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
