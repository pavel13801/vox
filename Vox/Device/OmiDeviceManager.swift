import Foundation
import CoreBluetooth
import Combine

/// BLE UUIDs used by the open-source Omi firmware (see BasedHardware/omi, app/lib/services/devices/models.dart).
enum OmiUUID {
    static let service = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    static let audioData = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    static let audioCodec = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")

    static let timeSyncService = CBUUID(string: "19B10030-E8F2-537E-4F6C-D104768A1214")
    static let timeSyncWrite = CBUUID(string: "19B10031-E8F2-537E-4F6C-D104768A1214")

    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    static let deviceInfoService = CBUUID(string: "180A")
    static let modelNumber = CBUUID(string: "2A24")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let manufacturer = CBUUID(string: "2A29")
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var isOmi: Bool
}

/// Manages scanning, connecting and streaming audio from an Omi wearable.
/// All CoreBluetooth callbacks are delivered on the main queue.
final class OmiDeviceManager: NSObject, ObservableObject {
    static let shared = OmiDeviceManager()

    enum ConnectionState: Equatable {
        case unavailable(String)
        case idle
        case scanning
        case connecting
        case connected
        case reconnecting
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var codec: OmiCodec?
    @Published private(set) var firmware: String?
    @Published private(set) var model: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var isStreaming = false
    @Published private(set) var lostFrames = 0
    @Published var showAllDevices = false

    /// Decoded PCM16 mono, sample rate = `currentSampleRate`.
    var onPCM: ((Data) -> Void)?
    /// Called when the audio stream becomes ready (true) or the device disconnects (false).
    var onReadyChange: ((Bool) -> Void)?

    private(set) var currentSampleRate: Double = 16000

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var decoder: OmiAudioDecoder?
    private var wantsConnection = false
    private var lostCounterTick = 0

    private let savedKey = "omi.savedDeviceID"
    private let savedNameKey = "omi.savedDeviceName"

    var savedDeviceID: UUID? {
        get { UserDefaults.standard.string(forKey: savedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: savedKey) }
    }

    var savedDeviceName: String? {
        get { UserDefaults.standard.string(forKey: savedNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: savedNameKey) }
    }

    var isConnected: Bool { state == .connected }
    var isReady: Bool { state == .connected && isStreaming }

    private override init() {
        super.init()
    }

    /// Creating the central manager triggers the Bluetooth permission prompt, so do it lazily.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    var hasSavedDevice: Bool { savedDeviceID != nil }

    // MARK: Public API

    func startScan() {
        activate()
        guard central.state == .poweredOn else { return }
        discovered = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, self.state == .scanning else { return }
            self.stopScan()
        }
    }

    func stopScan() {
        guard central != nil else { return }
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(to id: UUID) {
        activate()
        guard central.state == .poweredOn else { return }
        stopScan()
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        savedDeviceID = id
        savedDeviceName = p.name ?? discovered.first(where: { $0.id == id })?.name
        wantsConnection = true
        connectPeripheral(p)
    }

    func reconnectSaved() {
        activate()
        guard central.state == .poweredOn, let id = savedDeviceID else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        wantsConnection = true
        connectPeripheral(p)
    }

    func disconnect(forget: Bool) {
        wantsConnection = false
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        if forget {
            savedDeviceID = nil
            savedDeviceName = nil
        }
        cleanup()
        state = .idle
    }

    // MARK: Internals

    private func connectPeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? savedDeviceName
        state = .connecting
        // A pending connect never times out on iOS: the phone reconnects as soon as the device is in range.
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: false,
        ])
    }

    private func cleanup() {
        let wasStreaming = isStreaming
        audioChar = nil
        decoder = nil
        isStreaming = false
        batteryLevel = nil
        if wasStreaming { onReadyChange?(false) }
    }

    private func handleAudio(_ value: Data) {
        guard let decoder = decoder else { return }
        let pcm = decoder.decode(packet: [UInt8](value))
        if !pcm.isEmpty { onPCM?(pcm) }
        lostCounterTick += 1
        if lostCounterTick >= 200 {
            lostCounterTick = 0
            if lostFrames != decoder.lostFrames { lostFrames = decoder.lostFrames }
        }
    }

    private func syncTime(_ p: CBPeripheral, _ c: CBCharacteristic) {
        var epoch = UInt32(Date().timeIntervalSince1970).littleEndian
        let data = withUnsafeBytes(of: &epoch) { Data($0) }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: c, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension OmiDeviceManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if case .unavailable = state { state = .idle }
            if savedDeviceID != nil { reconnectSaved() }
        case .poweredOff:
            cleanup()
            state = .unavailable("Bluetooth выключен")
        case .unauthorized:
            state = .unavailable("Нет доступа к Bluetooth — разрешите в Настройках")
        case .unsupported:
            state = .unavailable("Bluetooth не поддерживается")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let lower = name.lowercased()
        let isOmi = services.contains(OmiUUID.service) || lower.contains("omi") || lower.contains("friend")
        guard isOmi || (showAllDevices && !name.isEmpty) else { return }
        let item = DiscoveredDevice(id: peripheral.identifier, name: name.isEmpty ? "Без имени" : name, rssi: RSSI.intValue, isOmi: isOmi)
        if let i = discovered.firstIndex(where: { $0.id == item.id }) {
            discovered[i] = item
        } else {
            discovered.append(item)
            discovered.sort { ($0.isOmi ? 1 : 0, $0.rssi) > ($1.isOmi ? 1 : 0, $1.rssi) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        deviceName = peripheral.name ?? savedDeviceName
        if let name = peripheral.name { savedDeviceName = name }
        peripheral.discoverServices([OmiUUID.service, OmiUUID.batteryService, OmiUUID.deviceInfoService, OmiUUID.timeSyncService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cleanup()
        if wantsConnection {
            state = .reconnecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, self.wantsConnection else { return }
                self.connectPeripheral(peripheral)
            }
        } else {
            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanup()
        if wantsConnection {
            connectPeripheral(peripheral)
            state = .reconnecting
        } else {
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension OmiDeviceManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            switch s.uuid {
            case OmiUUID.service:
                peripheral.discoverCharacteristics([OmiUUID.audioData, OmiUUID.audioCodec], for: s)
            case OmiUUID.batteryService:
                peripheral.discoverCharacteristics([OmiUUID.batteryLevel], for: s)
            case OmiUUID.deviceInfoService:
                peripheral.discoverCharacteristics([OmiUUID.firmwareRevision, OmiUUID.modelNumber], for: s)
            case OmiUUID.timeSyncService:
                peripheral.discoverCharacteristics([OmiUUID.timeSyncWrite], for: s)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case OmiUUID.audioCodec:
                peripheral.readValue(for: c)
            case OmiUUID.audioData:
                audioChar = c
                // Subscribe once the codec is known (see didUpdateValue for audioCodec).
                if decoder != nil { peripheral.setNotifyValue(true, for: c) }
            case OmiUUID.batteryLevel:
                peripheral.readValue(for: c)
                if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
            case OmiUUID.firmwareRevision, OmiUUID.modelNumber:
                peripheral.readValue(for: c)
            case OmiUUID.timeSyncWrite:
                syncTime(peripheral, c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case OmiUUID.audioData:
            handleAudio(value)
        case OmiUUID.audioCodec:
            let id = value.first.map { Int($0) } ?? 1
            let codec = OmiCodec(id: id)
            self.codec = codec
            currentSampleRate = codec.sampleRate
            decoder = OmiAudioDecoder(codec: codec)
            if let a = audioChar { peripheral.setNotifyValue(true, for: a) }
        case OmiUUID.batteryLevel:
            if let b = value.first { batteryLevel = Int(b) }
        case OmiUUID.firmwareRevision:
            firmware = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        case OmiUUID.modelNumber:
            model = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == OmiUUID.audioData else { return }
        let streaming = characteristic.isNotifying && error == nil
        if streaming != isStreaming {
            isStreaming = streaming
            onReadyChange?(streaming)
        }
    }
}
