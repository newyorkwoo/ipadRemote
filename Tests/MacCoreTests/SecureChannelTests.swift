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

/// Mac 端真正的 RemoteServer：心跳、hello 後才取代舊連線（iPad 同時從多個位址連入）
final class RemoteServerTests: XCTestCase {
    private func makeServer(code: String, port: UInt16) -> RemoteServer {
        let server = RemoteServer()
        server.streamingEnabled = false   // 測試不擷取螢幕
        server.hostInfoProvider = {
            HostInfo(hostID: "t", computerName: "Test", model: "", isLaptop: true, displays: [], inputSources: [])
        }
        let listening = expectation(description: "listening")
        listening.assertForOverFulfill = false
        server.onStatus = { _, ok in if ok { listening.fulfill() } }
        server.start(pairingCode: code, port: port, serviceName: "UnitTest-\(UUID().uuidString.prefix(4))", hostID: "test")
        wait(for: [listening], timeout: 5)
        return server
    }

    final class Flag { var value = false }

    private func connect(_ code: String, _ port: UInt16, hello: Bool) -> (TestClient, XCTestExpectation, Flag) {
        let ready = expectation(description: "ready")
        let closed = Flag()
        let client = TestClient(code: code, port: port)
        client.onState = { state in
            switch state {
            case .ready:
                if hello {
                    client.channel.send(ClientMessage.hello(clientName: "iPad", protocolVersion: 1, quality: .low, displayID: nil))
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
            case .hello, .pong: ready.fulfill()
            default: break
            }
        }
        client.start()
        return (client, ready, closed)
    }

    func testPingWorksAndRacingConnectionDoesNotKickActiveOne() throws {
        let code = PairingCode.generate()
        let port: UInt16 = 52_877
        let server = makeServer(code: code, port: port)
        _ = server

        let (a, aReady, aClosed) = connect(code, port, hello: true)
        wait(for: [aReady], timeout: 5)

        // 另一條平行嘗試的連線（沒送 hello）不應踢掉正在控制的連線
        let (b, bReady, _) = connect(code, port, hello: false)
        wait(for: [bReady], timeout: 5)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(aClosed.value, "沒送 hello 的平行連線不應踢掉正在控制的連線")
        b.cancel()

        // 真正的重連（送 hello）才取代舊連線
        let aReplaced = expectation(description: "a replaced")
        aReplaced.assertForOverFulfill = false
        a.channel.onReceiveError = { _ in aReplaced.fulfill() }
        let (c, cReady, _) = connect(code, port, hello: true)
        wait(for: [cReady, aReplaced], timeout: 5)
        c.cancel()
    }
}
