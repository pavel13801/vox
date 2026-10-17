import Foundation
import AVFoundation

/// Appends raw 16-bit little-endian mono PCM to a file. Crash-safe: whatever was
/// written survives an app kill and can be converted later.
final class PCMFileWriter {
    let url: URL
    private var handle: FileHandle?
    private(set) var bytesWritten: Int64 = 0

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        if let end = try? handle?.seekToEnd() {
            bytesWritten = Int64(end)
        }
    }

    func append(_ data: Data) {
        guard let handle = handle, !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += Int64(data.count)
        } catch {
            // Disk full or similar — nothing sensible to do mid-recording.
        }
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}

enum AudioFiles {
    /// Converts a raw PCM16 mono file into AAC (.m4a). Falls back to WAV if the AAC encoder refuses.
    /// Returns the produced file name.
    static func finalizeRecording(pcmURL: URL, sampleRate: Double, folder: URL) throws -> String {
        let m4a = folder.appendingPathComponent("audio.m4a")
        do {
            try encodePCMToAAC(pcmURL: pcmURL, sampleRate: sampleRate, outURL: m4a)
            try? FileManager.default.removeItem(at: pcmURL)
            return m4a.lastPathComponent
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            let wav = folder.appendingPathComponent("audio.wav")
            try writeWAV(fromPCM: pcmURL, sampleRate: sampleRate, to: wav)
            try? FileManager.default.removeItem(at: pcmURL)
            return wav.lastPathComponent
        }
    }

    static func encodePCMToAAC(pcmURL: URL, sampleRate: Double, outURL: URL) throws {
        try? FileManager.default.removeItem(at: outURL)
        let bitrate = sampleRate >= 16000 ? 32000 : 16000
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]
        let reader = try FileHandle(forReadingFrom: pcmURL)
        defer { try? reader.close() }

        func makeFile() throws -> AVAudioFile {
            do {
                return try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            } catch {
                settings.removeValue(forKey: AVEncoderBitRateKey)
                settings[AVEncoderAudioQualityKey] = AVAudioQuality.medium.rawValue
                return try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            }
        }

        // Scope so the AVAudioFile is released (and the file finalized) before returning.
        try autoreleasepool {
            let file = try makeFile()
            let format = file.processingFormat
            let chunkFrames = Int(sampleRate) * 10
            while true {
                let data = try reader.read(upToCount: chunkFrames * 2) ?? Data()
                if data.isEmpty { break }
                let frames = data.count / 2
                guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { break }
                buffer.frameLength = AVAudioFrameCount(frames)
                data.withUnsafeBytes { raw in
                    if let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                        memcpy(dst, src, frames * 2)
                    }
                }
                try file.write(from: buffer)
            }
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: outURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size < 64 { throw VoxError.message("AAC файл пустой") }
    }

    static func wavHeader(dataSize: Int, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        let byteRate = sampleRate * channels * bitsPerSample / 8
        h.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(channels * bitsPerSample / 8))
        u16(UInt16(bitsPerSample))
        h.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))
        return h
    }

    static func writeWAV(fromPCM pcmURL: URL, sampleRate: Double, to wavURL: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: pcmURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        try? FileManager.default.removeItem(at: wavURL)
        FileManager.default.createFile(atPath: wavURL.path, contents: wavHeader(dataSize: size, sampleRate: Int(sampleRate)))
        let out = try FileHandle(forWritingTo: wavURL)
        defer { try? out.close() }
        try out.seekToEnd()
        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    static func wavData(pcm: Data, sampleRate: Int) -> Data {
        var d = wavHeader(dataSize: pcm.count, sampleRate: sampleRate)
        d.append(pcm)
        return d
    }

    /// Splits any readable audio file into 16 kHz mono WAV chunks (for Whisper-style APIs with size limits).
    static func splitToWAVChunks(source: URL, chunkSeconds: Double, into dir: URL) throws -> [(url: URL, offset: Double)] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try AVAudioFile(forReading: source)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VoxError.message("Не удалось подготовить конвертер аудио")
        }
        let readFrames: AVAudioFrameCount = 32768
        var results: [(URL, Double)] = []
        var current = Data()
        let chunkBytes = Int(chunkSeconds * 16000) * 2
        var chunkIndex = 0
        var producedSamples = 0
        var chunkStartSample = 0
        var reachedEnd = false

        func flush() throws {
            guard !current.isEmpty else { return }
            let url = dir.appendingPathComponent(String(format: "chunk_%03d.wav", chunkIndex))
            try wavData(pcm: current, sampleRate: 16000).write(to: url)
            results.append((url, Double(chunkStartSample) / 16000))
            chunkIndex += 1
            chunkStartSample = producedSamples
            current = Data()
        }

        while !reachedEnd {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32768) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: readFrames) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: readFrames)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw convError ?? VoxError.message("Ошибка конвертации аудио") }
            if outBuf.frameLength > 0, let ch = outBuf.int16ChannelData {
                current.append(Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2))
                producedSamples += Int(outBuf.frameLength)
                if current.count >= chunkBytes { try flush() }
            }
            if status == .endOfStream { reachedEnd = true }
            if status == .inputRanDry && outBuf.frameLength == 0 { reachedEnd = true }
        }
        try flush()
        return results.map { (url: $0.0, offset: $0.1) }
    }

    static func duration(of url: URL) -> Double {
        if let f = try? AVAudioFile(forReading: url) {
            let rate = f.fileFormat.sampleRate
            if rate > 0 { return Double(f.length) / rate }
        }
        return 0
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        case "caf": return "audio/x-caf"
        case "aiff", "aif": return "audio/aiff"
        case "amr": return "audio/amr"
        default: return "application/octet-stream"
        }
    }
}
