import SwiftUI

@main
struct VoxApp: App {
    @StateObject private var store = AppStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var recorder = RecordingController.shared
    @StateObject private var device = OmiDeviceManager.shared
    @StateObject private var processing = ProcessingQueue.shared
    @StateObject private var chat = ChatService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(recorder)
                .environmentObject(device)
                .environmentObject(processing)
                .environmentObject(chat)
                .task {
                    await store.load()
                    recorder.bootstrap()
                    processing.resumePending(excluding: recorder.conversationID)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if device.hasSavedDevice { device.reconnectSaved() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Записи", systemImage: "waveform") }
                .tag(0)
            TasksView()
                .tabItem { Label("Задачи", systemImage: "checklist") }
                .tag(1)
            ChatView()
                .tabItem { Label("Чат", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(2)
            MemoriesView()
                .tabItem { Label("Память", systemImage: "brain") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(4)
        }
        .overlay {
            if !store.isLoaded {
                ProgressView("Загрузка…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
