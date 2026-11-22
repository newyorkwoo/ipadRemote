import Foundation

/// 已配對的 iPad（Mac 端）。每台有自己的 256-bit 金鑰，可個別移除。
struct PairedDevice: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?

    var credential: PSKCredential { .device(id: id, key: key) }
}

/// 存放已配對 iPad 的清單與金鑰（存在鑰匙圈；keychainAccount 為 nil 時只放記憶體，測試用）
final class PairedDeviceStore {
    private let lock = NSLock()
    private var devices: [PairedDevice]
    private let keychainAccount: String?

    init(keychainAccount: String?) {
        self.keychainAccount = keychainAccount
        if let account = keychainAccount,
           let json = Keychain.get(account),
           let decoded = try? JSONDecoder().decode([PairedDevice].self, from: Data(json.utf8)) {
            devices = decoded
        } else {
            devices = []
        }
    }

    var all: [PairedDevice] { lock.withLock { devices } }

    func key(for id: String) -> Data? {
        lock.withLock { devices.first(where: { $0.id == id })?.key }
    }

    /// 新配對：產生專屬金鑰
    func add(name: String) -> PairedDevice {
        let device = PairedDevice(id: UUID().uuidString, name: name, key: PSKCredential.newDeviceKey(),
                                  pairedAt: Date(), lastSeen: Date())
        lock.withLock { devices.append(device) }
        persist()
        return device
    }

    func remove(id: String) {
        lock.withLock { devices.removeAll { $0.id == id } }
        persist()
    }

    /// 更新名稱與最後連線時間
    func touch(id: String, name: String) {
        lock.withLock {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            devices[index].name = name
            devices[index].lastSeen = Date()
        }
        persist()
    }

    private func persist() {
        guard let account = keychainAccount else { return }
        let snapshot = all
        if let data = try? JSONEncoder().encode(snapshot) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: account)
        }
    }
}
