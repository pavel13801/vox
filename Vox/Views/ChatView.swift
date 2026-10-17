import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var chat: ChatService
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ChatThreadView(scope: nil)
                .navigationTitle("Чат с записями")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            chat.clear(scope: nil)
                        } label: { Image(systemName: "trash") }
                        .disabled(store.chatMessages.isEmpty)
                    }
                }
        }
    }
}

struct ChatThreadView: View {
    let scope: UUID?

    @EnvironmentObject private var chat: ChatService
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @State private var input = ""
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] {
        if let scope = scope { return chat.scopedMessages[scope] ?? [] }
        return store.chatMessages
    }

    private var suggestions: [String] {
        if scope != nil {
            return ["О чём была эта запись?", "Какие решения приняли?", "Что я пообещал сделать?", "Составь письмо по итогам"]
        }
        return ["Что я делал сегодня?", "Какие у меня открытые задачи?", "О чём мы договорились на этой неделе?", "Что ты обо мне знаешь?"]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !settings.llmConfigured {
                            EmptyStateView(icon: "key",
                                           title: "Нужен ключ ИИ",
                                           message: "Добавьте ключ в Настройки → Ключи API и выберите модель (например, бесплатный Gemini).")
                        } else if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(scope == nil ? "Спросите что угодно о своих записях" : "Спросите об этой записи")
                                    .font(.headline)
                                ForEach(suggestions, id: \.self) { s in
                                    Button {
                                        chat.send(s, scope: scope)
                                    } label: {
                                        Text(s)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 20)
                        }
                        ForEach(messages) { m in
                            ChatBubble(message: m, isStreaming: chat.isResponding && m.id == messages.last?.id && m.role == "assistant")
                                .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.text) { _, _ in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Сообщение", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                if chat.isResponding {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32))
                    }
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(input.trimmed.isEmpty || !settings.llmConfigured)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func send() {
        let text = input
        input = ""
        chat.send(text, scope: scope)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && isStreaming {
                    ProgressView().padding(4)
                } else if message.role == "user" {
                    Text(message.text).textSelection(.enabled)
                } else {
                    MarkdownText(text: message.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(message.role == "user" ? Color.accentColor.opacity(0.18) :
                          (message.isError ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground)))
            )
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: { Label("Копировать", systemImage: "doc.on.doc") }
            }
            if message.role != "user" { Spacer(minLength: 20) }
        }
    }
}
