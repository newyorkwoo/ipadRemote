import XCTest
import Network

/// 加密連線：交握、大量資料、順序、錯誤配對碼、線路上無明文
final class SecureChannelTests: XCTestCase {
    private let code = PairingCode.generate()

    func testHandshakeControlAndLargeVideoMessage() throws {
        let server = try LoopbackServer(code: code)
        let bigPayload = Data((0..<5_000_000).map { UInt8($0 % 253) })
        server.onControl = { channel, data in
            if case .ping(let id) = decodeClient(data) {
                channel.send(ServerMessage.pong(id: id))
                channel.sendVideo(VideoPacket(isKeyframe: true, parameterSets: [Data([1])], payload: bigPayload).serialized())
            }
        }
        let port = server.start()
        defer { server.stop() }

        let pong = expectation(description: "pong")
        let video = expectation(description: "video")
        let client = TestClient(code: code, port: port)
        client.onState = { if case .ready = $0 { client.channel.send(ClientMessage.ping(id: 42)) } }
        client.onControl = { if case .pong(42) = decodeServer($0) { pong.fulfill() } }
        client.onVideo = { data in
            let packet = VideoPacket(data: data)
            XCTAssertEqual(packet?.payload, bigPayload, "5 MB 影像封包必須完整無誤")
            video.fulfill()
        }
        client.start()
        wait(for: [pong, video], timeout: 10, enforceOrder: true)
        client.cancel()
    }

    func testThousandsOfInputEventsArriveInOrder() throws {
        let server = try LoopbackServer(code: code)
        let count = 3000
        var received: [Double] = []
        let done = expectation(description: "all events")
        server.onControl = { _, data in
            if case let .mouseMove(x, _) = decodeClient(data) {
                received.append(x)
                if received.count == count { done.fulfill() }
            }
        }
        let port = server.start()
        defer { server.stop() }

        let client = TestClient(code: code, port: port)
        client.onState = { state in
            guard case .ready = state else { return }
            for i in 0..<count { client.channel.send(ClientMessage.mouseMove(x: Double(i), y: 0)) }
        }
        client.start()
        wait(for: [done], timeout: 15)
        XCTAssertEqual(received, (0..<count).map(Double.init), "滑鼠事件必須按順序抵達")
        client.cancel()
    }

    func testForwardSecretCipherSuiteIsNegotiated() throws {
        let server = try LoopbackServer(code: code)
        let port = server.start()
        defer { server.stop() }
        let ready = expectation(description: "ready")
        let client = TestClient(code: code, port: port)
        client.onState = { if case .ready = $0 { ready.fulfill() } }
        client.start()
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(SecureTransport.negotiatedCipherSuite(client.connection)?.rawValue,
                       UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256),
                       "必須使用 ECDHE-PSK（前向保密），不可退回純 PSK")
        client.cancel()
    }

    func testDeviceProofMatchesOnBothEndsAndIsBoundToTheConnection() throws {
        let key = PSKCredential.newDeviceKey()
        let server = try LoopbackServer(code: code)
        let port = server.start()
        defer { server.stop() }

        func proofs() -> (client: Data?, server: Data?) {
            let ready = expectation(description: "ready")
            let client = TestClient(code: code, port: port)
            client.onState = { if case .ready = $0 { ready.fulfill() } }
            client.start()
            wait(for: [ready], timeout: 5)
            Thread.sleep(forTimeInterval: 0.2)
            let serverConnection = server.channels.last?.connection
            defer { client.cancel() }
            return (SecureTransport.deviceProof(key: key, connection: client.connection),
                    serverConnection.flatMap { SecureTransport.deviceProof(key: key, connection: $0) })
        }
        let first = proofs()
        XCTAssertNotNil(first.client)
        XCTAssertEqual(first.client, first.server, "兩端算出的裝置證明必須一致")
        let second = proofs()
        XCTAssertNotEqual(first.client, second.client, "每條連線的證明不同，錄下來也無法重送")
        XCTAssertNotEqual(SecureTransport.deviceProof(key: PSKCredential.newDeviceKey(), connection: server.channels.last!.connection),
                          second.server, "不同金鑰的證明必須不同")
    }

    func testWrongPairingCodeIsRejectedAndNothingIsDelivered() throws {
        let server = try LoopbackServer(code: code)
        var serverGotMessage = false
        server.onControl = { _, _ in serverGotMessage = true }
        let port = server.start()
        defer { server.stop() }

        let rejected = expectation(description: "TLS rejected")
        let client = TestClient(code: PairingCode.generate(), port: port)
        client.onState = { state in
            switch state {
            case .ready:
                XCTFail("錯誤的配對碼不應該能建立連線")
            case .failed(let error), .waiting(let error):
                XCTAssertTrue(error.isTLS, "應該是 TLS 交握錯誤，實際為 \(error)")
                rejected.fulfill()
                client.cancel()
            default:
                break
            }
        }
        client.start()
        wait(for: [rejected], timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(serverGotMessage)
    }

    func testTrafficOnTheWireIsEncrypted() throws {
        let server = try LoopbackServer(code: code)
        let secretText = "SECRET-PASSWORD-我的密碼-1234567890"
        let got = expectation(description: "server got text")
        server.onControl = { channel, data in
            if case .text(let text, _) = decodeClient(data), text == secretText {
                channel.send(ServerMessage.notice("REPLY-" + secretText))
                got.fulfill()
            }
        }
        let serverPort = server.start()
        let proxy = try SniffingProxy(targetPort: serverPort)
        let proxyPort = proxy.start()
        defer { proxy.stop(); server.stop() }

        let reply = expectation(description: "reply")
        let client = TestClient(code: code, port: proxyPort)
        client.onState = { if case .ready = $0 { client.channel.send(ClientMessage.text(secretText, usePaste: false)) } }
        client.onControl = { if case .notice = decodeServer($0) { reply.fulfill() } }
        client.start()
        wait(for: [got, reply], timeout: 10)
        client.cancel()

        let wire = proxy.capturedBytes
        XCTAssertGreaterThan(wire.count, 100, "代理應該有轉送到資料")
        for needle in ["SECRET-PASSWORD", "我的密碼", "\"text\"", "REPLY-"] {
            XCTAssertNil(wire.range(of: Data(needle.utf8)), "線路上出現明文：\(needle)")
        }
        // TLS record header：0x17 = application data, 0x03 0x03 = TLS 1.2
        XCTAssertNotNil(wire.range(of: Data([0x17, 0x03, 0x03])), "應看到 TLS 加密資料記錄")
    }
}

/// Mac 端真正的 RemoteServer：配對、裝置金鑰、hello 後才取代舊連線、hello 前不接受輸入
final class RemoteServerTests: XCTestCase {
    final class Flag { var value = false }
    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private var codeChanges: [String] = []
    private var injected = Box<[CGEvent]>([])

    private func makeServer(code: String, port: UInt16) -> RemoteServer {
        let server = RemoteServer()   // 金鑰只放記憶體，不碰鑰匙圈
        server.streamingEnabled = false   // 測試不擷取螢幕
        server.hostInfoProvider = {
            HostInfo(hostID: "t", computerName: "Test", model: "", isLaptop: true, displays: [], inputSources: [])
        }
        let events = injected
        server.configureInjector = { injector in
            injector.post = { event in DispatchQueue.main.async { events.value.append(event) } }
            injector.cursorLocation = { CGPoint(x: 10, y: 10) }
            injector.activateWindow = { _ in }
        }
        server.onPairingCodeChanged = { [unowned self] in self.codeChanges.append($0) }
        let listening = expectation(description: "listening")
        listening.assertForOverFulfill = false
        server.onStatus = { _, ok in if ok { listening.fulfill() } }
        server.start(pairingCode: code, port: port, serviceName: "UnitTest-\(UUID().uuidString.prefix(4))", hostID: "test")
        wait(for: [listening], timeout: 5)
        return server
    }

    struct Connected {
        let client: TestClient
        let ready: XCTestExpectation
        let closed: Flag
        let paired: Box<PSKCredential?>
    }

    /// identify：用裝置金鑰連線時先送裝置證明
    private func connect(_ credential: PSKCredential, _ port: UInt16, hello: Bool,
                         identifyAs deviceID: String? = nil, beforeHello: [ClientMessage] = []) -> Connected {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        let closed = Flag()
        let paired = Box<PSKCredential?>(nil)
        let client = TestClient(credential: credential, port: port)
        client.onState = { state in
            switch state {
            case .ready:
                beforeHello.forEach { client.channel.send($0) }
                if let deviceID, let proof = SecureTransport.deviceProof(key: credential.key, connection: client.connection) {
                    client.channel.send(ClientMessage.identify(deviceID: deviceID, proof: proof))
                }
                if hello {
                    client.channel.send(ClientMessage.hello(clientName: "iPad", protocolVersion: RemoteConstants.protocolVersion, quality: .low, displayID: nil))
                } else {
                    client.channel.send(ClientMessage.ping(id: 1))
                }
            case .failed, .cancelled: closed.value = true
            default: break
            }
        }
        client.channel.onReceiveError = { _ in closed.value = true }
        client.onControl = { data in
            switch decodeServer(data) {
            case let .paired(id, key): paired.value = .device(id: id, key: key)
            case .hello, .pong: ready.fulfill()
            default: break
            }
        }
        client.start()
        return Connected(client: client, ready: ready, closed: closed, paired: paired)
    }

    private func expectRejected(_ credential: PSKCredential, _ port: UInt16, _ message: String) {
        let rejected = expectation(description: message)
        rejected.assertForOverFulfill = false
        let client = TestClient(credential: credential, port: port)
        client.onState = { state in
            switch state {
            case .ready: XCTFail(message)
            case .failed(let error), .waiting(let error):
                XCTAssertTrue(error.isTLS, "應為 TLS 交握錯誤：\(error)")
                rejected.fulfill()
                client.cancel()
            default: break
            }
        }
        client.start()
        wait(for: [rejected], timeout: 10)
    }

    private func pingWorks(_ client: TestClient) -> Bool {
        let pong = expectation(description: "pong")
        pong.assertForOverFulfill = false
        client.onControl = { if case .pong(77) = decodeServer($0) { pong.fulfill() } }
        client.channel.send(ClientMessage.ping(id: 77))
        return XCTWaiter().wait(for: [pong], timeout: 3) == .completed
    }

    func testPingWorksAndRacingConnectionDoesNotKickActiveOne() throws {
        let code = PairingCode.generate()
        let port: UInt16 = 52_877
        let server = makeServer(code: code, port: port)
        _ = server

        let a = connect(.pairing(code), port, hello: true)
        wait(for: [a.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        guard let deviceKey = a.paired.value else { return XCTFail("第一次連線應完成配對並收到裝置金鑰") }
        let deviceID = String(deviceKey.identity.dropFirst("device:".count))

        // 另一條平行嘗試的連線（沒送 hello）不應踢掉正在控制的連線
        let b = connect(deviceKey, port, hello: false)
        wait(for: [b.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(a.closed.value, "沒送 hello 的平行連線不應踢掉正在控制的連線")
        b.client.cancel()

        // 真正的重連（用裝置金鑰 + 證明 + hello）才取代舊連線，而且不會再配對一次
        let aReplaced = expectation(description: "a replaced")
        aReplaced.assertForOverFulfill = false
        a.client.channel.onReceiveError = { _ in aReplaced.fulfill() }
        let c = connect(deviceKey, port, hello: true, identifyAs: deviceID)
        wait(for: [c.ready, aReplaced], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(c.paired.value, "已配對的 iPad 重連時不應再配對一次")
        XCTAssertEqual(codeChanges.count, 1)
        c.client.cancel()
    }

    func testPairingCodeIsOneTimeAndDeviceKeysCanBeRevokedIndividually() throws {
        let code = PairingCode.generate()
        let port: UInt16 = 52_878
        let server = makeServer(code: code, port: port)

        let a = connect(.pairing(code), port, hello: true)
        wait(for: [a.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        guard let keyA = a.paired.value else { return XCTFail("應收到裝置金鑰") }
        XCTAssertEqual(codeChanges.count, 1, "配對成功後應自動更換配對碼")
        XCTAssertEqual(server.devices.all.count, 1)
        XCTAssertTrue(pingWorks(a.client), "更換配對碼重新監聽時，不可中斷已建立的連線")

        expectRejected(.pairing(code), port, "用過的配對碼不能再用")

        // 第二台 iPad 用新的配對碼配對
        let newCode = codeChanges[0]
        let b = connect(.pairing(newCode), port, hello: true)
        wait(for: [b.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        guard let keyB = b.paired.value else { return XCTFail("第二台應收到裝置金鑰") }
        b.client.cancel()

        // 移除 A：A 的連線被中斷、之後無法交握；B 不受影響
        let idA = String(keyA.identity.dropFirst("device:".count))
        let idB = String(keyB.identity.dropFirst("device:".count))
        // （B 送 hello 時已取代 A 的控制權）A 用自己的金鑰重新連上，再從 Mac 移除它
        a.client.cancel()
        let a2 = connect(keyA, port, hello: true, identifyAs: idA)
        wait(for: [a2.ready], timeout: 5)
        let aDropped = expectation(description: "A dropped")
        aDropped.assertForOverFulfill = false
        a2.client.channel.onReceiveError = { _ in aDropped.fulfill() }
        server.removeDevice(id: idA)
        wait(for: [aDropped], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        expectRejected(keyA, port, "被移除的 iPad 不應能再連線")

        let b2 = connect(keyB, port, hello: true, identifyAs: idB)
        wait(for: [b2.ready], timeout: 5)
        XCTAssertEqual(server.devices.all.map(\.id), [idB])
        b2.client.cancel()
    }

    func testForgedDeviceProofDoesNotIdentifyAsThatDevice() throws {
        let code = PairingCode.generate()
        let port: UInt16 = 52_879
        let server = makeServer(code: code, port: port)
        let a = connect(.pairing(code), port, hello: true)
        wait(for: [a.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        guard let keyA = a.paired.value else { return XCTFail("應收到裝置金鑰") }
        a.client.cancel()
        let idA = String(keyA.identity.dropFirst("device:".count))

        // 持有新配對碼的人假冒 A（送出錯誤的證明）→ 不被認成 A，而是當作新配對
        let forger = TestClient(credential: .pairing(codeChanges[0]), port: port)
        let gotPaired = expectation(description: "treated as new pairing")
        forger.onControl = { if case .paired = decodeServer($0) { gotPaired.fulfill() } }
        forger.onState = { state in
            guard case .ready = state else { return }
            forger.channel.send(ClientMessage.identify(deviceID: idA, proof: Data(repeating: 0, count: 32)))
            forger.channel.send(ClientMessage.hello(clientName: "假冒", protocolVersion: 3, quality: .low, displayID: nil))
        }
        forger.start()
        wait(for: [gotPaired], timeout: 5)
        XCTAssertEqual(server.devices.all.first(where: { $0.id == idA })?.name, "iPad", "假冒者不可改到 A 的資料")
        forger.cancel()
    }

    func testInputIsIgnoredBeforeHelloAndBadValuesDoNotCrash() throws {
        let code = PairingCode.generate()
        let port: UInt16 = 52_880
        let server = makeServer(code: code, port: port)
        _ = server
        let early: [ClientMessage] = [
            .key(keyCode: MacKey.a, down: true, modifiers: []),
            .text("偷打的字", usePaste: false),
            .click(button: .left, clickCount: 1, modifiers: []),
        ]
        let a = connect(.pairing(code), port, hello: false, beforeHello: early)
        wait(for: [a.ready], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(injected.value.isEmpty, "hello 之前的輸入一律不處理")

        a.client.channel.send(ClientMessage.hello(clientName: "iPad", protocolVersion: 3, quality: .low, displayID: nil))
        a.client.channel.send(ClientMessage.videoAck(count: Int.min))
        a.client.channel.send(ClientMessage.videoAck(count: Int.max))
        a.client.channel.send(ClientMessage.scroll(dx: 1e300, dy: -1e300))
        a.client.channel.send(ClientMessage.keyPress(keyCode: MacKey.a, modifiers: []))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(pingWorks(a.client), "異常數值不可讓 Mac 端當掉")
        let flush = expectation(description: "flush")
        DispatchQueue.main.async { flush.fulfill() }
        wait(for: [flush], timeout: 1)
        XCTAssertTrue(injected.value.contains { $0.type == .keyDown }, "hello 之後的輸入應正常處理")
        a.client.cancel()
    }
}
