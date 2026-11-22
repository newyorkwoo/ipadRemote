import XCTest
import Network
import CoreMedia
import AVFoundation
@testable import iPadRemote

// MARK: - 模擬 Mac 的伺服器

/// 可以「睡眠」、「被喚醒」、「靜默當機」的假 Mac
final class SimulatedMac {
    let code: String
    let port: UInt16
    let mac = "AA:BB:CC:00:11:22"
    let queue = DispatchQueue(label: "sim.mac")
    private var listener: NWListener?
    private var channels: [MessageChannel] = []
    private let lock = NSLock()
    private var _received: [ClientMessage] = []
    private var _connections = 0
    /// true 時收到訊息不回應也不斷線（模擬網路黑洞 / 半開連線）
    var silent = false
    /// hello 中回報給 iPad 的位址（模擬 Mac 有區網 IP + Tailscale IP）
    var addresses: [String]? = nil
    /// 與真正的 Mac 相同：用配對碼連線並送 hello → 發給 iPad 專屬裝置金鑰（事先產生，監聽時就已接受）
    let deviceID = "sim-device-\(UUID().uuidString.prefix(8))"
    let deviceKey = PSKCredential.newDeviceKey()
    /// false 時模擬「Mac 已移除這台 iPad」：不再接受裝置金鑰
    var acceptsDeviceKey = true
    private var identified = Set<ObjectIdentifier>()
    private(set) var pairingsIssued = 0
    private(set) var verifiedIdentities = 0

    var received: [ClientMessage] { lock.withLock { _received } }

    /// 模擬 Mac 送出聲音封包給所有已連線的 iPad
    func pushAudio(_ data: Data) {
        queue.async { self.channels.forEach { $0.sendAudio(data) } }
    }

    func pushVideo(_ data: Data) {
        queue.async { self.channels.forEach { $0.sendVideo(data) } }
    }
    var connectionCount: Int { lock.withLock { _connections } }

    init(code: String, port: UInt16) {
        self.code = code
        self.port = port
    }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        var credentials = [PSKCredential.pairing(code)]
        if acceptsDeviceKey { credentials.append(.device(id: deviceID, key: deviceKey)) }
        let params = SecureTransport.parameters(credentials: credentials)
        params.allowLocalEndpointReuse = true
        let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        self.listener = listener
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "模擬 Mac 無法開始監聽")
    }

    /// 模擬 Mac 進入睡眠：中斷所有連線並停止監聽
    func sleep() {
        listener?.cancel()
        listener = nil
        channels.forEach { $0.connection.cancel() }
        channels.removeAll()
    }

    func dropConnections() {
        channels.forEach { $0.connection.cancel() }
        channels.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { _connections += 1 }
        let channel = MessageChannel(connection: connection)
        channels.append(channel)
        channel.onControl = { [weak self, weak channel] data in
            guard let self, let channel, let message = try? JSONDecoder().decode(ClientMessage.self, from: data) else { return }
            self.lock.withLock { self._received.append(message) }
            guard !self.silent else { return }
            switch message {
            case let .identify(id, proof):
                if id == self.deviceID,
                   let expected = SecureTransport.deviceProof(key: self.deviceKey, connection: channel.connection),
                   SecureTransport.constantTimeEqual(expected, proof) {
                    self.lock.withLock {
                        self.identified.insert(ObjectIdentifier(channel))
                        self.verifiedIdentities += 1
                    }
                }
            case .hello:
                let known = self.lock.withLock { self.identified.contains(ObjectIdentifier(channel)) }
                if !known {
                    self.lock.withLock { self.pairingsIssued += 1 }
                    channel.send(ServerMessage.paired(deviceID: self.deviceID, key: self.deviceKey))
                }
                channel.send(ServerMessage.hello(HostInfo(
                    hostID: "sim-host", computerName: "模擬 Mac", model: "Mac16,1", isLaptop: true,
                    macAddress: self.mac, otherMACAddresses: ["AA:BB:CC:00:11:99"],
                    ipv4: "127.0.0.1", broadcast: "127.255.255.255", addresses: self.addresses,
                    displays: [DisplayInfo(id: 1, name: "內建", width: 1440, height: 900, isMain: true)],
                    inputSources: [InputSourceInfo(id: "abc", name: "ABC", isSelected: true),
                                   InputSourceInfo(id: "zhuyin", name: "注音", isSelected: false)])))
            case .ping(let id):
                channel.send(ServerMessage.pong(id: id))
            case .selectInputSource(let id):
                channel.send(ServerMessage.inputSources([
                    InputSourceInfo(id: "abc", name: "ABC", isSelected: id == "abc"),
                    InputSourceInfo(id: "zhuyin", name: "注音", isSelected: id == "zhuyin")]))
            default:
                break
            }
        }
        connection.stateUpdateHandler = { if case .ready = $0 { channel.startReceiving() } }
        connection.start(queue: queue)
    }
}

/// 接收 Wake-on-LAN 封包的 UDP 監聽器
final class MagicPacketListener {
    private let fd: Int32
    private(set) var packets: [Data] = []
    private let lock = NSLock()
    var onPacket: ((Data) -> Void)?

    init(port: UInt16) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let fd = self.fd
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while let self {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    self.lock.withLock { self.packets.append(data) }
                    self.onPacket?(data)
                } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            }
        }
    }

    var received: [Data] { lock.withLock { packets } }
    func close() { Darwin.close(fd) }
}

// MARK: - 工具

extension XCTestCase {
    /// 一邊跑主執行緒 RunLoop（RemoteClient 在主執行緒運作）一邊等條件成立
    @discardableResult
    func waitUntil(_ description: String, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("逾時：\(description)")
        return false
    }
}

private var nextPort: UInt16 = 53_200

private func makeDevice(code: String, port: UInt16, wakePort: UInt16 = 9, mac: String = "") -> SavedMac {
    var device = SavedMac(name: "測試 Mac")
    device.host = "127.0.0.1"
    device.port = port
    device.macAddress = mac
    device.wakeHost = "127.0.0.1"
    device.wakePort = wakePort
    Keychain.set(code, for: SavedMac.keychainAccount(device.id))
    return device
}

// MARK: - 連線、重連、喚醒

final class RemoteClientTests: XCTestCase {
    private var port: UInt16 = 0
    private let code = PairingCode.generate()

    override func setUp() {
        nextPort += 1
        port = nextPort
    }

    func testConnectHelloAndDeviceInfoIsLearned() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }

        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        var learned: HostInfo?
        client.onHostInfo = { info, _ in learned = info }
        client.connect()
        defer { client.disconnect() }

        waitUntil("連線成功", timeout: 5) { client.state == .connected }
        XCTAssertEqual(client.hostInfo?.computerName, "模擬 Mac")
        XCTAssertEqual(client.inputSources.map(\.name), ["ABC", "注音"])
        XCTAssertEqual(learned?.macAddress, mac.mac, "第一次連線就要記住 MAC 位址供日後喚醒")
        XCTAssertEqual(client.device.macAddress, mac.mac)
        XCTAssertEqual(client.device.otherMACAddresses, ["AA:BB:CC:00:11:99"])
        if case let .hello(_, version, quality, _) = mac.received.first(where: { if case .hello = $0 { return true }; return false }) {
            XCTAssertEqual(version, RemoteConstants.protocolVersion)
            XCTAssertEqual(quality, .balanced)
        } else {
            XCTFail("第一個訊息應為 hello")
        }
    }

    func testHeartbeatMeasuresLatencyAndInputIsDelivered() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        client.send(.text("你好，Mac", usePaste: false))
        client.send(.click(button: .left, clickCount: 2, modifiers: .command))
        client.send(.selectInputSource(id: "zhuyin"))
        waitUntil("Mac 回報輸入法已切換", timeout: 3) {
            client.inputSources.first(where: \.isSelected)?.name == "注音"
        }
        waitUntil("心跳測得延遲", timeout: 5) { client.latencyMs != nil }
        XCTAssertLessThan(client.latencyMs ?? 999, 200)

        let received = mac.received
        XCTAssertTrue(received.contains { if case .text("你好，Mac", false) = $0 { return true }; return false })
        XCTAssertTrue(received.contains { if case .click(.left, 2, .command) = $0 { return true }; return false })
    }

    func testAutoReconnectAfterConnectionDrops() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        for round in 1...3 {
            mac.dropConnections()   // 模擬網路瞬斷
            waitUntil("第 \(round) 次偵測到斷線", timeout: 3) {
                if case .reconnecting = client.state { return true }
                return false
            }
            waitUntil("第 \(round) 次自動重新連上", timeout: 5) { client.state == .connected }
        }
        XCTAssertEqual(mac.connectionCount, 4)
    }

    func testReconnectsWhenMacComesBackAfterLongOutage() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect(); mac.sleep() }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        mac.sleep()
        // 停機 6 秒，期間應持續重試而不放棄
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        guard case let .reconnecting(attempt, _) = client.state else {
            return XCTFail("應處於重連狀態，實際為 \(client.state)")
        }
        XCTAssertGreaterThanOrEqual(attempt, 4)

        mac.start()
        waitUntil("Mac 回來後自動連上", timeout: 7) { client.state == .connected }
    }

    /// 核心情境：Mac 睡眠 → iPad 自動送 Wake-on-LAN → Mac 被喚醒 → 自動連上
    func testSleepingMacIsAutomaticallyWokenAndReconnected() {
        let wakePort = port + 1000
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        let wakeListener = MagicPacketListener(port: wakePort)
        defer { wakeListener.close(); mac.sleep() }

        var woke = false
        wakeListener.onPacket = { packet in
            // 收到正確的魔術封包才「醒來」
            guard !woke, WakeOnLAN.magicPacket(for: mac.mac) == packet else { return }
            woke = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { mac.start() }
        }

        let client = RemoteClient(device: makeDevice(code: code, port: port, wakePort: wakePort), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        mac.sleep()
        waitUntil("iPad 自動送出喚醒封包", timeout: 8) { woke }
        XCTAssertNotNil(client.lastWakeSent)
        waitUntil("喚醒後自動重新連線", timeout: 8) { client.state == .connected }

        let packets = wakeListener.received
        XCTAssertTrue(packets.allSatisfy { $0.count == 102 })
        XCTAssertTrue(packets.contains(WakeOnLAN.magicPacket(for: "AA:BB:CC:00:11:99")!), "其他 MAC（硬體位址）也要送")
    }

    func testHeartbeatDetectsSilentlyDeadConnection() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        // TCP 還開著但完全沒有回應（例如 Wi‑Fi 卡住、Mac 當機）
        mac.silent = true
        let start = Date()
        waitUntil("心跳逾時偵測到斷線", timeout: 12) {
            if case .reconnecting = client.state { return true }
            return false
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 11)
        mac.silent = false
        waitUntil("恢復後重新連上", timeout: 8) { client.state == .connected }
    }

    /// iPad 與 Mac 在不同網路：沒有 Bonjour、沒填外部位址，只靠第一次連線時學到的位址，
    /// 其中混有連不到的區網 IP（另一個網路的 192.x），必須同時嘗試並很快從可用的路徑連上
    func testDifferentNetworkUsesLearnedAddressesAndRacesPaths() {
        let mac = SimulatedMac(code: code, port: port)
        mac.addresses = ["192.0.2.55", "127.0.0.1"]   // 192.0.2.0/24 為不可路由的測試網段
        mac.start()
        defer { mac.sleep() }

        // 第一次：在同一個網路（以手動位址模擬）連線，學到 Mac 的所有位址
        let first = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        first.connect()
        waitUntil("第一次連線", timeout: 5) { first.state == .connected }
        var learned = first.device
        first.disconnect()
        XCTAssertEqual(learned.knownAddresses, ["192.0.2.55", "127.0.0.1"])

        // 換到另一個網路：清掉手動位址，最後已知 IP 指向連不到的區網
        learned.host = ""
        learned.lastIPv4 = "192.0.2.55"
        let second = RemoteClient(device: learned, browser: BonjourBrowser())
        let endpoints = second.candidateEndpoints().map { "\($0)" }
        XCTAssertEqual(endpoints.count, 2, "應同時嘗試所有學到的位址（不重複）：\(endpoints)")

        let start = Date()
        second.connect()
        defer { second.disconnect() }
        waitUntil("透過學到的位址自動連上", timeout: 4) { second.state == .connected }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "不應被連不到的位址拖慢")
    }

    func testTailscaleAddressesArePreferredAndDetected() {
        XCTAssertTrue(NetworkAddress.isTailscale("100.101.102.103"))
        XCTAssertTrue(NetworkAddress.isTailscale("100.64.0.1"))
        XCTAssertFalse(NetworkAddress.isTailscale("100.128.0.1"))
        XCTAssertFalse(NetworkAddress.isTailscale("192.168.1.2"))
        var device = SavedMac(name: "x")
        device.knownAddresses = ["192.168.1.20", "100.90.1.2"]
        XCTAssertTrue(device.hasRemoteRoute)
        XCTAssertEqual(device.tailscaleAddress, "100.90.1.2")
        let client = RemoteClient(device: device, browser: BonjourBrowser())
        XCTAssertTrue("\(client.candidateEndpoints().first!)".contains("100.90.1.2"), "Tailscale 位址應排在前面")
        device.knownAddresses = ["192.168.1.20"]
        XCTAssertFalse(device.hasRemoteRoute)
    }

    func testWrongPairingCodeStopsWithClearError() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let client = RemoteClient(device: makeDevice(code: PairingCode.generate(), port: port), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }

        waitUntil("顯示配對碼錯誤", timeout: 10) {
            if case .failed(let message) = client.state { return message.contains("配對碼") }
            return false
        }
        XCTAssertTrue(mac.received.isEmpty, "配對碼錯誤時 Mac 不應收到任何指令")
    }

    // MARK: 安全：一次性配對碼 → 專屬裝置金鑰

    func testFirstConnectionPairsThenReconnectsWithDeviceKeyOnly() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let device = makeDevice(code: code, port: port)
        let client = RemoteClient(device: device, browser: BonjourBrowser())
        client.connect()
        waitUntil("連線", timeout: 5) { client.state == .connected }
        waitUntil("收到裝置金鑰", timeout: 3) { device.isPaired }
        XCTAssertEqual(device.credential?.deviceID, mac.deviceID)
        XCTAssertEqual(device.pairingCode, "", "配對成功後，已失效的配對碼要從鑰匙圈刪除")
        client.disconnect()

        // 配對碼已從 iPad 刪除，只剩裝置金鑰：仍能連上，且證明身分、不會重新配對
        mac.sleep()
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // 等連接埠釋放
        mac.start()
        let again = RemoteClient(device: device, browser: BonjourBrowser())
        again.connect()
        defer { again.disconnect() }
        waitUntil("用裝置金鑰重新連線", timeout: 5) { again.state == .connected }
        XCTAssertEqual(mac.pairingsIssued, 1, "已配對的 iPad 不應再配對一次")
        XCTAssertEqual(mac.verifiedIdentities, 1, "重連時應送出正確的裝置證明")
        Keychain.delete(SavedMac.credentialAccount(device.id))
    }

    func testRemovedDeviceStopsWithClearError() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let device = makeDevice(code: code, port: port)
        let client = RemoteClient(device: device, browser: BonjourBrowser())
        client.connect()
        waitUntil("配對", timeout: 5) { client.state == .connected && device.isPaired }
        client.disconnect()

        mac.sleep()
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // 等連接埠釋放
        mac.acceptsDeviceKey = false     // Mac 上移除了這台 iPad
        mac.start()
        let again = RemoteClient(device: device, browser: BonjourBrowser())
        again.connect()
        defer { again.disconnect() }
        waitUntil("提示已被移除、需重新配對", timeout: 10) {
            if case .failed(let message) = again.state { return message.contains("移除") }
            return false
        }
        Keychain.delete(SavedMac.credentialAccount(device.id))
    }

    func testInputIsNotSentWhileAppIsLocked() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let device = makeDevice(code: code, port: port)
        let client = RemoteClient(device: device, browser: BonjourBrowser())
        client.connect()
        defer {
            client.disconnect()
            Keychain.delete(SavedMac.credentialAccount(device.id))
        }
        waitUntil("連線", timeout: 5) { client.state == .connected }

        client.inputBlocked = true
        client.send(.text("鎖定中打的字", usePaste: false))
        client.send(.keyPress(keyCode: 0, modifiers: []))
        client.send(.click(button: .left, clickCount: 1, modifiers: []))
        client.send(.requestKeyframe)   // 非輸入類訊息照常送出
        client.inputBlocked = false
        client.send(.text("解鎖後", usePaste: false))
        waitUntil("解鎖後的輸入送達", timeout: 3) {
            mac.received.contains { if case .text("解鎖後", _) = $0 { return true }; return false }
        }
        let received = mac.received
        XCTAssertFalse(received.contains { if case .text("鎖定中打的字", _) = $0 { return true }; return false })
        XCTAssertFalse(received.contains { if case .keyPress = $0 { return true }; return false })
        XCTAssertFalse(received.contains { if case .click = $0 { return true }; return false })
        XCTAssertTrue(received.contains { if case .requestKeyframe = $0 { return true }; return false })
    }

    func testUserDisconnectStopsReconnecting() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }
        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.connect()
        waitUntil("連線", timeout: 5) { client.state == .connected }
        client.disconnect()
        let count = mac.connectionCount
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(client.state, .idle)
        XCTAssertEqual(mac.connectionCount, count, "使用者主動結束後不應再重連")
        XCTAssertTrue(mac.received.contains { if case .goodbye = $0 { return true }; return false })
    }
}

// MARK: - Wake-on-LAN、鍵盤對應、影像

final class WakeOnLANTests: XCTestCase {
    func testMagicPacketFormat() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(for: "50:f2:65:ED:EE:0F"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0x50, 0xF2, 0x65, 0xED, 0xEE, 0x0F]
        for i in 0..<16 {
            XCTAssertEqual(Array(packet[(6 + i * 6)..<(12 + i * 6)]), mac)
        }
        XCTAssertEqual(WakeOnLAN.magicPacket(for: "50-F2-65-ED-EE-0F"), packet, "接受 - 分隔")
        XCTAssertNil(WakeOnLAN.magicPacket(for: "50:F2:65"))
        XCTAssertNil(WakeOnLAN.magicPacket(for: ""))
    }

    func testTargetsIncludeBroadcastLastIPAndExternalHost() {
        var device = SavedMac(name: "x")
        device.lastIPv4 = "192.168.1.20"
        device.lastBroadcast = "192.168.1.255"
        device.wakeHost = "home.example.net"
        device.wakePort = 4009
        let targets = Set(WakeOnLAN.targets(for: device).map { "\($0.host):\($0.port)" })
        XCTAssertEqual(targets, ["255.255.255.255:9", "192.168.1.255:9", "192.168.1.20:9", "home.example.net:4009"])
    }

    func testManualWakeSendsRealUDPPackets() {
        let port: UInt16 = 54_321
        let listener = MagicPacketListener(port: port)
        defer { listener.close() }
        var device = SavedMac(name: "x")
        device.macAddress = "11:22:33:44:55:66"
        device.wakeHost = "127.0.0.1"
        device.wakePort = port
        var sent = -1
        WakeOnLAN.wake(device) { sent = $0 }
        waitUntil("送出", timeout: 3) { sent >= 0 && !listener.received.isEmpty }
        XCTAssertGreaterThanOrEqual(sent, 1)
        XCTAssertEqual(listener.received.first, WakeOnLAN.magicPacket(for: device.macAddress))
    }
}

final class KeyMapTests: XCTestCase {
    func testHardwareKeyboardMapping() {
        let cases: [(UIKeyboardHIDUsage, UInt16)] = [
            (.keyboardA, 0x00), (.keyboardS, 0x01), (.keyboardZ, 0x06), (.keyboardQ, 0x0C),
            (.keyboard1, 0x12), (.keyboard0, 0x1D), (.keyboardReturnOrEnter, MacKey.returnKey),
            (.keyboardDeleteOrBackspace, MacKey.delete), (.keyboardTab, MacKey.tab), (.keyboardSpacebar, MacKey.space),
            (.keyboardEscape, MacKey.escape), (.keyboardLeftArrow, MacKey.left), (.keyboardUpArrow, MacKey.up),
            (.keyboardLeftGUI, MacKey.command), (.keyboardLeftAlt, MacKey.option), (.keyboardLeftShift, MacKey.shift),
            (.keyboardLeftControl, MacKey.control), (.keyboardCapsLock, MacKey.capsLock),
            (.keyboardF1, MacKey.f1), (.keyboardF12, MacKey.f12), (.keyboardSemicolon, 0x29),
            (.keyboardLANG1, MacKey.kana), (.keyboardLANG2, MacKey.eisu),
        ]
        for (usage, expected) in cases {
            XCTAssertEqual(KeyMap.macKeyCode(for: usage), expected, "HID \(usage.rawValue)")
        }
        XCTAssertEqual(KeyMap.modifiers(from: [.command, .shift]), [.command, .shift])
        XCTAssertEqual(KeyMap.modifiers(from: [.alternate, .control]), [.option, .control])
    }
}

final class VideoRendererTests: XCTestCase {
    /// 讀取由 Mac 端 H264Encoder 產生的真實封包（Tools/make-h264-fixtures.swift）
    static func fixture(_ name: String) throws -> [Data] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "bin"))
        let data = try Data(contentsOf: url)
        var packets: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            packets.append(data.subdata(in: offset..<offset + length))
            offset += length
        }
        return packets
    }

    func testRendererDecodesStreamAndReportsSize() throws {
        let frames = try Self.fixture("h264_640x400")
        XCTAssertEqual(frames.count, 10)
        let renderer = VideoRenderer()
        var size: CGSize?
        var keyframeRequests = 0
        renderer.onSizeChange = { size = $0 }
        renderer.onNeedKeyframe = { keyframeRequests += 1 }

        // 重連時若先收到差異幀，應要求關鍵幀而不是顯示花屏
        renderer.handle(frames[1])
        XCTAssertEqual(keyframeRequests, 1)
        XCTAssertNil(size)

        for frame in frames { renderer.handle(frame) }
        XCTAssertEqual(size, CGSize(width: 640, height: 400))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNotEqual(renderer.displayLayer.sampleBufferRenderer.status, .failed, "解碼器不應出錯")
        XCTAssertEqual(keyframeRequests, 1)
    }

    func testResolutionChangeIsDetected() throws {
        let renderer = VideoRenderer()
        var sizes: [CGSize] = []
        renderer.onSizeChange = { sizes.append($0) }
        try Self.fixture("h264_640x400").prefix(3).forEach(renderer.handle)
        try Self.fixture("h264_1280x720").forEach(renderer.handle)
        XCTAssertEqual(sizes, [CGSize(width: 640, height: 400), CGSize(width: 1280, height: 720)])
    }

    func testGarbageDataDoesNotCrash() {
        let renderer = VideoRenderer()
        for _ in 0..<500 {
            renderer.handle(Data((0..<Int.random(in: 0...200)).map { _ in UInt8.random(in: 0...255) }))
        }
    }
}

// MARK: - 聲音

final class RemoteAudioTests: XCTestCase {
    private var port: UInt16 = 0
    private let code = PairingCode.generate()

    override func setUp() {
        nextPort += 1
        port = nextPort
        UserDefaults.standard.set(true, forKey: "audioEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "audioEnabled")
    }

    private func toneFrames(seconds: Double) -> [Data] {
        let encoder = AACEncoder()
        let chunk: AVAudioFrameCount = 480
        var frames: [Data] = []
        for start in stride(from: 0, to: Int(seconds * RemoteAudio.sampleRate), by: Int(chunk)) {
            let buffer = AVAudioPCMBuffer(pcmFormat: RemoteAudio.pcmFormat, frameCapacity: chunk)!
            buffer.frameLength = chunk
            for i in 0..<Int(chunk) {
                let v = Float(sin(2 * .pi * 660 * Double(start + i) / RemoteAudio.sampleRate)) * 0.4
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            let packets = encoder.encode(buffer)
            if !packets.isEmpty { frames.append(AudioPacket(packets: packets).serialized()) }
        }
        return frames
    }

    /// Mac 送來的聲音在 iPad 解碼；關閉聲音後會通知 Mac 並停止處理
    func testAudioIsDecodedAndCanBeTurnedOff() {
        let mac = SimulatedMac(code: code, port: port)
        mac.start()
        defer { mac.sleep() }

        let client = RemoteClient(device: makeDevice(code: code, port: port), browser: BonjourBrowser())
        client.audio.outputEnabled = false   // 測試不實際出聲
        let lock = NSLock()
        var decodedFrames = 0
        var peak: Float = 0
        client.audio.onDecoded = { buffer in
            lock.withLock {
                decodedFrames += Int(buffer.frameLength)
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
            }
        }
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }
        XCTAssertTrue(client.audioEnabled)
        waitUntil("連線時告訴 Mac 要傳聲音", timeout: 3) {
            mac.received.contains { if case .setAudio(true) = $0 { return true }; return false }
        }

        toneFrames(seconds: 1).forEach(mac.pushAudio)
        waitUntil("iPad 解碼約 1 秒聲音", timeout: 5) { lock.withLock { decodedFrames } > 40_000 }
        XCTAssertEqual(lock.withLock { peak }, 0.4, accuracy: 0.1, "解碼後的音量應正確")

        client.audioEnabled = false
        waitUntil("關閉聲音時通知 Mac", timeout: 3) {
            mac.received.contains { if case .setAudio(false) = $0 { return true }; return false }
        }
        let before = lock.withLock { decodedFrames }
        toneFrames(seconds: 0.5).forEach(mac.pushAudio)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(lock.withLock { decodedFrames }, before, "關閉後不應再處理聲音")
    }
}

// MARK: - 低延遲

final class LowLatencyTests: XCTestCase {
    /// iPad 在背景佇列處理影像，並為每一幀回報 videoAck（Mac 據此限制在途幀數，避免網路緩衝造成延遲）
    func testEveryVideoFrameIsAcknowledgedAndDecodedOffMainThread() throws {
        nextPort += 1
        let code = PairingCode.generate()
        let mac = SimulatedMac(code: code, port: nextPort)
        mac.start()
        defer { mac.sleep() }

        let client = RemoteClient(device: makeDevice(code: code, port: nextPort), browser: BonjourBrowser())
        client.connect()
        defer { client.disconnect() }
        waitUntil("連線", timeout: 5) { client.state == .connected }
        if case let .hello(_, version, _, _) = mac.received.first(where: { if case .hello = $0 { return true }; return false }) {
            XCTAssertGreaterThanOrEqual(version, 2, "要宣告支援流量控制")
        }

        let frames = try VideoRendererTests.fixture("h264_640x400")
        frames.forEach(mac.pushVideo)
        waitUntil("每一幀都回報", timeout: 5) {
            mac.received.reduce(0) { if case let .videoAck(n) = $1 { return $0 + n }; return $0 } == frames.count
        }
        waitUntil("畫面尺寸更新到主執行緒", timeout: 3) { client.videoSize == CGSize(width: 640, height: 400) }

        // 主執行緒被卡住時，影像仍在背景繼續處理與回報
        let before = mac.received.count
        frames.forEach(mac.pushVideo)
        Thread.sleep(forTimeInterval: 0.6)   // 刻意卡住主執行緒
        let acks = mac.received.dropFirst(before).filter { if case .videoAck = $0 { return true }; return false }.count
        XCTAssertEqual(acks, frames.count, "主執行緒忙碌時影像也不應被延誤")
    }
}
