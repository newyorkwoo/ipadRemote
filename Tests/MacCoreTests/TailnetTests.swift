import XCTest
import Darwin

/// 內嵌 Tailscale 的純邏輯部分：節點命名、位元組對接（不連到真正的 tailnet；完整流程見 Tools/TailnetE2E）
final class TailnetTests: XCTestCase {

    // MARK: 節點命名

    func testMacHostNameRoundTrip() {
        let hostID = "3F2A1B4C-1111-2222-3333-444455556666"
        let name = TailnetNaming.macHostName(computerName: "Steven's MacBook Pro", hostID: hostID)
        XCTAssertEqual(name, "ipadremote-mac-3f2a1b4c-steven-s-macbook-pro")
        let parsed = TailnetNaming.parseMac(name)
        XCTAssertEqual(parsed?.idTag, "3f2a1b4c")
        XCTAssertEqual(parsed?.displayName, "steven s macbook pro")
        XCTAssertTrue(TailnetNaming.matches(hostID: hostID, idTag: parsed!.idTag))
        XCTAssertFalse(TailnetNaming.matches(hostID: UUID().uuidString, idTag: parsed!.idTag))
        XCTAssertFalse(TailnetNaming.matches(hostID: nil, idTag: parsed!.idTag))
    }

    func testNonASCIIComputerNameStillValidDNSLabel() {
        let name = TailnetNaming.macHostName(computerName: "史蒂芬的 Mac mini", hostID: "abcdef01-0000")
        XCTAssertEqual(name, "ipadremote-mac-abcdef01-mac-mini")
        let onlyChinese = TailnetNaming.macHostName(computerName: "書房電腦", hostID: "abcdef01-0000")
        XCTAssertEqual(onlyChinese, "ipadremote-mac-abcdef01")
        XCTAssertEqual(TailnetNaming.parseMac(onlyChinese)?.displayName, "Mac")
        XCTAssertLessThanOrEqual(TailnetNaming.macHostName(computerName: String(repeating: "x", count: 200),
                                                           hostID: "abcdef01").count, 63)
    }

    func testOtherNodesAreNotMacs() {
        XCTAssertNil(TailnetNaming.parseMac(TailnetNaming.iPadHostName(deviceName: "iPad")))
        XCTAssertNil(TailnetNaming.parseMac("stevens-macbook"))
        XCTAssertNil(TailnetNaming.parseMac("ipadremote-mac-xyz"))
        XCTAssertEqual(TailnetNaming.iPadHostName(deviceName: ""), "ipadremote-ipad-ipad")
    }

    // MARK: 位元組對接

    /// tailnet 連線（以 socketpair 模擬）↔ 本機 TCP：雙向資料完整、順序不變
    func testBridgeCopiesBothDirectionsIntact() throws {
        let listener = try XCTUnwrap(OneShotLoopbackListener())
        var tailnetSide: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &tailnetSide), 0)

        let accepted = expectation(description: "accept")
        DispatchQueue.global().async {
            if let local = listener.acceptOnce(timeout: 5) {
                TCPBridge.pump(local, tailnetSide[1])
            }
            accepted.fulfill()
        }
        let client = try XCTUnwrap(LoopbackSocket.connect(port: listener.port))
        wait(for: [accepted], timeout: 5)

        // 5 MB 隨機資料，模擬影像串流
        let payload = (0..<5_000_000).map { _ in UInt8.random(in: 0...255) }
        let reader = Thread.detachedRead(fd: tailnetSide[0], count: payload.count)
        writeAll(client, payload)
        XCTAssertEqual(reader.wait(), payload)

        // 反方向
        let reply = Array("pong from mac".utf8)
        let back = Thread.detachedRead(fd: client, count: reply.count)
        writeAll(tailnetSide[0], reply)
        XCTAssertEqual(back.wait(), reply)

        close(client)
        close(tailnetSide[0])
    }

    /// 一端斷線，另一端也會被關閉（iPad 才能偵測到斷線並重連）
    func testBridgeClosesPeerWhenOneSideCloses() throws {
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &a), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &b), 0)
        let closed = expectation(description: "closed")
        TCPBridge.pump(a[1], b[1]) { closed.fulfill() }
        close(a[0])
        wait(for: [closed], timeout: 3)
        var byte: UInt8 = 0
        XCTAssertEqual(read(b[0], &byte, 1), 0, "另一端應收到 EOF")
        close(b[0])
    }

    func testOneShotListenerAcceptsOnlyOnce() throws {
        let listener = try XCTUnwrap(OneShotLoopbackListener())
        let port = listener.port
        XCTAssertNil(listener.acceptOnce(timeout: 0.2), "沒人連線時逾時回傳 nil")
        XCTAssertNil(LoopbackSocket.connect(port: port), "用過之後不再接受連線")
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}

private extension Thread {
    final class ReadResult {
        private let done = DispatchSemaphore(value: 0)
        var bytes: [UInt8] = []
        func finish() { done.signal() }
        func wait() -> [UInt8] { _ = done.wait(timeout: .now() + 10); return bytes }
    }

    static func detachedRead(fd: Int32, count: Int) -> ReadResult {
        let result = ReadResult()
        Thread.detachNewThread {
            var out = [UInt8](); out.reserveCapacity(count)
            var buf = [UInt8](repeating: 0, count: 65536)
            while out.count < count {
                let n = read(fd, &buf, min(buf.count, count - out.count))
                guard n > 0 else { break }
                out.append(contentsOf: buf[0..<n])
            }
            result.bytes = out
            result.finish()
        }
        return result
    }
}
