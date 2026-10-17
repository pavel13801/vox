import SwiftUI
import UIKit
import AVFoundation
import Combine

// MARK: - Markdown

/// Lightweight block Markdown renderer (headings, bullet/numbered lists, paragraphs, inline styles).
struct MarkdownText: View {
    let text: String
    var font: Font = .body

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(String, Int)
        case numbered(String, String)
        case paragraph(String)
        case spacer
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if out.last != .spacer { out.append(.spacer) }
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2)), indent))
            } else if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy({ $0.isNumber }),
                      dot != line.startIndex, line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                out.append(.numbered(String(line[line.startIndex..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                out.append(.paragraph(line))
            }
        }
        while out.last == .spacer { out.removeLast() }
        return out
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s)
                        .font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.bold()))
                        .padding(.top, 4)
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s).font(font)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s).font(font)
                    }
                case .paragraph(let s):
                    inline(s).font(font)
                case .spacer:
                    Color.clear.frame(height: 2)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Speaker colors

enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .red, .mint]
    static func color(_ speaker: Int) -> Color { colors[abs(speaker) % colors.count] }
}

// MARK: - Status badge

struct StatusBadge: View {
    let conversation: Conversation

    var body: some View {
        switch conversation.status {
        case .recording:
            Label("Запись", systemImage: "record.circle").font(.caption2).foregroundStyle(.red)
        case .transcribing, .summarizing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(conversation.status.label).font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Label("Ошибка", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        case .done:
            EmptyView()
        }
    }
}

// MARK: - Level meter

struct LevelMeter: View {
    let level: Float
    var bars = 24

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let threshold = Float(i) / Float(bars)
                    let active = min(1, level * 6) > threshold
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: max(2, (geo.size.width - CGFloat(bars) * 2) / CGFloat(bars)),
                               height: active ? geo.size.height * CGFloat(0.35 + 0.65 * Double(threshold)) : geo.size.height * 0.3)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

// MARK: - Share sheet

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Audio player

final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }
    @Published private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var url: URL?

    func load(_ url: URL) {
        guard self.url != url else { return }
        stop()
        self.url = url
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.enableRate = true
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
            loadError = nil
        } catch {
            loadError = "Не удалось открыть аудио: \(error.localizedDescription)"
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            stopTimer()
        } else {
            AudioSessionManager.activateForPlayback()
            p.rate = rate
            p.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(_ t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
    }

    func play(from t: Double) {
        seek(t)
        if !(player?.isPlaying ?? false) { toggle() }
    }

    func skip(_ delta: Double) { seek(currentTime + delta) }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        stopTimer()
        url = nil
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = 0
        }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        VStack(spacing: 6) {
            if let err = player.loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                   in: 0...max(player.duration, 0.1))
            HStack {
                Text(Formatters.clock(player.currentTime)).monospacedDigit()
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 38))
                }
                .padding(.horizontal, 12)
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Spacer()
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button(String(format: "%g×", r)) { player.rate = Float(r) }
                    }
                } label: {
                    Text(String(format: "%g×", Double(player.rate))).monospacedDigit()
                }
            }
            .font(.callout)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }
}

// MARK: - Misc

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }
}
