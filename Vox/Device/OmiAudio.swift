import Foundation
import Copus

/// Audio codecs advertised by the Omi firmware on the codec characteristic.
enum OmiCodec: Equatable {
    case pcm8      // id 1  — 16-bit PCM @ 8 kHz
    case pcm16     // id 0  — 16-bit PCM @ 16 kHz (old firmware)
    case opus      // id 20 — Opus 16 kHz, 10 ms frames
    case opusFS320 // id 21 — Opus 16 kHz, 20 ms frames
    case unknown(Int)

    init(id: Int) {
        switch id {
        case 0: self = .pcm16
        case 1: self = .pcm8
        case 20: self = .opus
        case 21: self = .opusFS320
        default: self = .unknown(id)
        }
    }

    var sampleRate: Double {
        switch self {
        case .pcm8: return 8000
        default: return 16000
        }
    }

    var isOpus: Bool {
        switch self {
        case .opus, .opusFS320: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .pcm8: return "PCM 8 кГц"
        case .pcm16: return "PCM 16 кГц"
        case .opus: return "Opus"
        case .opusFS320: return "Opus (320)"
        case .unknown(let id): return "Неизвестный (\(id))"
        }
    }
}

/// Thin wrapper over libopus.
final class OpusFrameDecoder {
    private var decoder: OpaquePointer?
    private let sampleRate: Int32
    private var pcm: [Int16]

    init?(sampleRate: Int32 = 16000) {
        self.sampleRate = sampleRate
        self.pcm = [Int16](repeating: 0, count: Int(sampleRate) * 120 / 1000)
        var err: Int32 = 0
        let d = opus_decoder_create(sampleRate, 1, &err)
        if err != 0 || d == nil { return nil }
        decoder = d
    }

    deinit {
        if let d = decoder { opus_decoder_destroy(d) }
    }

    func decode(_ frame: [UInt8]) -> Data? {
        guard let d = decoder, !frame.isEmpty else { return nil }
        let maxSamples = Int32(pcm.count)
        let n: Int32 = frame.withUnsafeBufferPointer { inPtr -> Int32 in
            pcm.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                opus_decode(d, inPtr.baseAddress, Int32(frame.count), outPtr.baseAddress!, maxSamples, 0)
            }
        }
        guard n > 0 else { return nil }
        return pcm.withUnsafeBufferPointer { ptr in
            Data(bytes: ptr.baseAddress!, count: Int(n) * 2)
        }
    }

    /// Packet-loss concealment for one missing frame.
    func concealLoss(samples: Int) -> Data? {
        guard let d = decoder, samples > 0, samples <= pcm.count else { return nil }
        let n: Int32 = pcm.withUnsafeMutableBufferPointer { outPtr -> Int32 in
            opus_decode(d, nil, 0, outPtr.baseAddress!, Int32(samples), 0)
        }
        guard n > 0 else { return nil }
        return pcm.withUnsafeBufferPointer { ptr in
            Data(bytes: ptr.baseAddress!, count: Int(n) * 2)
        }
    }
}

/// Re-assembles audio frames from Omi BLE notifications.
/// Each notification is: [packetIndex lo][packetIndex hi][frameSubIndex][payload…].
/// A frame may span several notifications (sub index 0, 1, 2…).
final class OmiFrameAssembler {
    private var lastPacketIndex = -1
    private var lastSubIndex = -1
    private var pending: [UInt8] = []
    private(set) var lostFrames = 0

    func reset() {
        lastPacketIndex = -1
        lastSubIndex = -1
        pending = []
    }

    /// Returns completed frames (usually zero or one per packet).
    func push(_ packet: [UInt8]) -> [[UInt8]] {
        guard packet.count > 3 else { return [] }
        let index = Int(packet[0]) | (Int(packet[1]) << 8)
        let sub = Int(packet[2])
        let content = Array(packet[3...])
        var out: [[UInt8]] = []

        if lastPacketIndex == -1 {
            if sub == 0 {
                lastPacketIndex = index
                lastSubIndex = 0
                pending = content
            }
            return out
        }

        let expected = (lastPacketIndex + 1) & 0xFFFF
        if index != expected || (sub != 0 && sub != lastSubIndex + 1) {
            // Lost packet(s): drop the partial frame and resync on the next frame start.
            lostFrames += 1
            if sub == 0 {
                lastPacketIndex = index
                lastSubIndex = 0
                pending = content
            } else {
                reset()
            }
            return out
        }

        if sub == 0 {
            if !pending.isEmpty { out.append(pending) }
            pending = content
        } else {
            pending.append(contentsOf: content)
        }
        lastSubIndex = sub
        lastPacketIndex = index
        return out
    }
}

/// Turns raw BLE notifications into 16-bit PCM according to the codec.
final class OmiAudioDecoder {
    let codec: OmiCodec
    private let assembler = OmiFrameAssembler()
    private let opus: OpusFrameDecoder?

    init(codec: OmiCodec) {
        self.codec = codec
        self.opus = codec.isOpus ? OpusFrameDecoder(sampleRate: 16000) : nil
    }

    var sampleRate: Double { codec.sampleRate }

    func decode(packet: [UInt8]) -> Data {
        var out = Data()
        for frame in assembler.push(packet) {
            if codec.isOpus {
                if let pcm = opus?.decode(frame) { out.append(pcm) }
            } else {
                out.append(contentsOf: frame)
            }
        }
        return out
    }

    var lostFrames: Int { assembler.lostFrames }
}
