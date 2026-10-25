import SwiftUI

// MARK: - Device

struct DeviceView: View {
    @EnvironmentObject private var device: OmiDeviceManager
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            if case .unavailable(let msg) = device.state {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            if device.hasSavedDevice {
                Section("Моё устройство") {
                    HStack {
                        Image(systemName: "circle.circle.fill").font(.title).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(device.deviceName ?? device.savedDeviceName ?? "Omi").font(.headline)
                            Text(stateText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let b = device.batteryLevel {
                            Label("\(b)%", systemImage: batteryIcon(b)).font(.callout).monospacedDigit()
                        }
                    }
                    if device.isConnected {
                        if let codec = device.codec { row("Кодек", codec.title) }
                        if let fw = device.firmware { row("Прошивка", fw) }
                        if let model = device.model { row("Модель", model) }
                        if device.lostFrames > 0 { row("Потеряно кадров", "\(device.lostFrames)") }
                        if !recorder.isRecording {
                            Button {
                                settings.preferredSource = .omi
                                Task { await recorder.start(source: .omi) }
                            } label: { Label("Начать запись с Omi", systemImage: "record.circle") }
                        }
                    } else {
                        Button { device.reconnectSaved() } label: { Label("Переподключить", systemImage: "arrow.clockwise") }
                    }
                    Button("Отключить и забыть", role: .destructive) { device.disconnect(forget: true) }
                }
            }

            Section {
                if device.state == .scanning {
                    HStack {
                        ProgressView()
                        Text("Ищу устройства…").foregroundStyle(.secondary)
                    }
                } else {
                    Button { device.startScan() } label: { Label("Найти устройство", systemImage: "magnifyingglass") }
                }
                ForEach(device.discovered) { d in
                    Button {
                        device.connect(to: d.id)
                    } label: {
                        HStack {
                            Image(systemName: d.isOmi ? "circle.circle.fill" : "dot.radiowaves.left.and.right")
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text("Сигнал \(d.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.id == device.savedDeviceID && device.isConnected {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Toggle("Показывать все Bluetooth-устройства", isOn: $device.showAllDevices)
            } header: {
                Text("Поиск")
            } footer: {
                Text("Включите Omi и держите рядом с iPhone. Если устройство подключено к официальному приложению Omi — сначала отключите его там. Vox будет сам переподключаться к кулону, как только он окажется рядом.")
            }
        }
        .navigationTitle("Omi")
        .onAppear { device.activate() }
        .onDisappear { device.stopScan() }
    }

    private var stateText: String {
        switch device.state {
        case .connected: return device.isStreaming ? "Подключено · звук идёт" : "Подключено"
        case .connecting: return "Подключение…"
        case .reconnecting: return "Ожидание устройства…"
        case .scanning: return "Поиск…"
        case .idle: return "Не в сети"
        case .unavailable(let m): return m
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

