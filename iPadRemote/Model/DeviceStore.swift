import Foundation
import Network
import Combine

/// 已配對的 Mac
struct SavedMac: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hostID: String?
    /// 外部連線位址（DDNS 網域、公網 IP 或 Tailscale IP），選填
    var host: String = ""
    var port: UInt16 = RemoteConstants.defaultPort
    var macAddress: String = ""
    var otherMACAddresses: [String]?
    var lastIPv4: String?
    var lastBroadcast: String?
    /// Mac 回報的所有可連入位址（區網、Tailscale），換到其他網路時自動嘗試
    var knownAddresses: [String]?
    /// 從外部網路喚醒：路由器的網址與轉發到區網廣播的 UDP 埠，選填
    var wakeHost: String = ""
    var wakePort: UInt16 = 9
    var model: String?
    var isLaptop: Bool = true
    var lastConnected: Date?
    var quality: StreamQuality = .balanced

    /// 尚未配對時使用的一次性配對碼（配對成功後即刪除）
    var pairingCode: String {
        Keychain.get(Self.keychainAccount(id)) ?? ""
    }

    /// Mac 發給這台 iPad 的專屬金鑰（配對成功後才有）
    var credential: DeviceCredential? {
        guard let json = Keychain.get(Self.credentialAccount(id)) else { return nil }
        return try? JSONDecoder().decode(DeviceCredential.self, from: Data(json.utf8))
    }

    var isPaired: Bool { credential != nil }
    var canConnect: Bool { isPaired || PairingCode.isValid(pairingCode) }

    static func keychainAccount(_ id: UUID) -> String { "device-\(id.uuidString)" }
    static func credentialAccount(_ id: UUID) -> String { "devicekey-\(id.uuidString)" }

    /// 配對完成：存下裝置金鑰，刪除已失效的配對碼
    static func storePairing(_ credential: DeviceCredential, for id: UUID) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        Keychain.set(String(decoding: data, as: UTF8.self), for: credentialAccount(id))
        Keychain.delete(keychainAccount(id))
    }
}

struct DeviceCredential: Codable, Equatable {
    var deviceID: String
    var key: Data
}

final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [SavedMac] = []
    private let key = "savedMacs.v1"

    init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedMac].self, from: data) {
            devices = decoded
        }
    }

    /// pairingCode 有效時 → 以新配對碼重新配對（舊的裝置金鑰作廢）；空白時保留現有配對
    func save(_ device: SavedMac, pairingCode: String) {
        if PairingCode.isValid(pairingCode) {
            Keychain.set(PairingCode.format(pairingCode), for: SavedMac.keychainAccount(device.id))
            Keychain.delete(SavedMac.credentialAccount(device.id))
        }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        persist()
    }

    func delete(_ device: SavedMac) {
        Keychain.delete(SavedMac.keychainAccount(device.id))
        Keychain.delete(SavedMac.credentialAccount(device.id))
        devices.removeAll { $0.id == device.id }
        persist()
    }

    func update(_ id: UUID, with info: HostInfo, quality: StreamQuality) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var device = devices[index]
        device.apply(info)
        device.quality = quality
        devices[index] = device
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension SavedMac {
    /// 是否有跨網路的連線方式（手動外部位址或 Tailscale）
    var hasRemoteRoute: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty || tailscaleAddress != nil
    }

    var tailscaleAddress: String? {
        knownAddresses?.first(where: NetworkAddress.isTailscale)
    }

    /// 連線成功後，自動記住 MAC 位址與 IP，日後即使 Mac 睡眠也能送喚醒封包
    mutating func apply(_ info: HostInfo) {
        hostID = info.hostID
        if let mac = info.macAddress { macAddress = mac }
        if let others = info.otherMACAddresses { otherMACAddresses = others }
        lastIPv4 = info.ipv4 ?? lastIPv4
        lastBroadcast = info.broadcast ?? lastBroadcast
        if let addresses = info.addresses, !addresses.isEmpty { knownAddresses = addresses }
        model = info.model
        isLaptop = info.isLaptop
        lastConnected = Date()
    }
}

// MARK: - Bonjour 探索

struct DiscoveredMac: Identifiable, Hashable {
    var id: String { hostID ?? name }
    var name: String
    var hostID: String?
    var endpoint: NWEndpoint
}

final class BonjourBrowser: ObservableObject {
    @Published private(set) var discovered: [DiscoveredMac] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteConstants.bonjourType, domain: nil),
                                using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.discovered = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var hostID: String?
                if case let .bonjour(txt) = result.metadata { hostID = txt["id"] }
                return DiscoveredMac(name: name, hostID: hostID, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.browser?.cancel()
                self?.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func endpoint(for device: SavedMac) -> NWEndpoint? {
        if let hostID = device.hostID, let match = discovered.first(where: { $0.hostID == hostID }) {
            return match.endpoint
        }
        return discovered.first(where: { $0.name == device.name })?.endpoint
    }

    func isOnline(_ device: SavedMac) -> Bool { endpoint(for: device) != nil }
}
