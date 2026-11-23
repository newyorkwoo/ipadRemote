import XCTest
import CryptoKit

final class PairingCodeTests: XCTestCase {
    func testGeneratedCodesAreValidUniqueAndWellFormed() {
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let codes = (0..<500).map { _ in PairingCode.generate() }
        XCTAssertEqual(Set(codes).count, codes.count, "配對碼不應重複")
        for code in codes {
            XCTAssertTrue(PairingCode.isValid(code))
            XCTAssertEqual(code.count, 23) // 20 字元 + 3 個 -
            XCTAssertEqual(code.split(separator: "-").count, 4)
            XCTAssertTrue(code.allSatisfy { $0 == "-" || alphabet.contains($0) }, "不應含易混淆字元：\(code)")
        }
    }

    func testNormalizationAcceptsUserTyping() {
        XCTAssertEqual(PairingCode.normalize("abcde-fghjk mnpqr stuvw"), "ABCDEFGHJKMNPQRSTUVW")
        XCTAssertTrue(PairingCode.isValid("abcde fghjk mnpqr stuvw"))
        XCTAssertFalse(PairingCode.isValid("ABCDE-FGHJK"))
        XCTAssertEqual(PairingCode.format("abcdefghjkmnpqrstuvw"), "ABCDE-FGHJK-MNPQR-STUVW")
    }

    func testPreSharedKeyIsDeterministicAndDistinct() {
        func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
        let a1 = bytes(PairingCode.preSharedKey(for: "ABCDE-FGHJK-MNPQR-STUVW"))
        let a2 = bytes(PairingCode.preSharedKey(for: "abcde fghjk mnpqr stuvw"))
        let b = bytes(PairingCode.preSharedKey(for: "ABCDE-FGHJK-MNPQR-STUVX"))
        XCTAssertEqual(a1.count, 32, "PSK 應為 256 bits")
        XCTAssertEqual(a1, a2, "同一配對碼不論格式都應得到相同金鑰")
        XCTAssertNotEqual(a1, b, "只差一個字元也必須是完全不同的金鑰")
    }
}

final class MessageCodingTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> Bool {
        // JSON 物件的欄位順序不固定，所以用 sortedKeys 比較
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: encoded)
        return try encoder.encode(decoded) == encoded
    }

    func testEveryClientMessageRoundTrips() throws {
        let messages: [ClientMessage] = [
            .hello(clientName: "iPad", protocolVersion: 1, quality: .high, displayID: 7),
            .hello(clientName: "iPad", protocolVersion: 1, quality: .low, displayID: nil),
            .ping(id: .max), .mouseMove(x: 0.25, y: 0.75), .mouseMoveRelative(dx: -0.01, dy: 0.02),
            .mouseButton(button: .right, down: true, clickCount: 1, modifiers: [.command, .shift]),
            .click(button: .left, clickCount: 2, modifiers: []), .scroll(dx: 3, dy: -12),
            .key(keyCode: MacKey.command, down: true, modifiers: []),
            .keyPress(keyCode: MacKey.c, modifiers: .command),
            .text("繁體中文 ㄅㄆㄇ 🙂 日本語", usePaste: false), .text("long", usePaste: true),
            .selectInputSource(id: "com.apple.inputmethod.TCIM.Zhuyin"), .nextInputSource,
            .selectDisplay(id: 2), .setQuality(.balanced), .requestKeyframe, .wakeDisplay, .goodbye,
            .setAudio(enabled: true), .setAudio(enabled: false), .videoAck(count: 1),
            .setInterfaceScale(.native), .setInterfaceScale(.larger),
        ]
        for message in messages {
            XCTAssertTrue(try roundTrip(message), "\(message)")
        }
    }

    func testEveryServerMessageRoundTrips() throws {
        let info = HostInfo(hostID: "id", computerName: "Steven 的 iMac", model: "iMac21,1", isLaptop: false,
                            macAddress: "AA:BB:CC:DD:EE:FF", ipv4: "192.168.1.20", broadcast: "192.168.1.255",
                            displays: [DisplayInfo(id: 1, name: "內建", width: 2560, height: 1440, isMain: true)],
                            inputSources: [InputSourceInfo(id: "abc", name: "ABC", isSelected: true)])
        let messages: [ServerMessage] = [
            .hello(info), .pong(id: 9), .inputSources(info.inputSources),
            .streamStarted(displayID: 1, pixelWidth: 1920, pixelHeight: 1080),
            .permissions(screenRecording: false, accessibility: true), .notice("提示"),
        ]
        for message in messages {
            XCTAssertTrue(try roundTrip(message), "\(message)")
        }
    }
}

final class VideoPacketTests: XCTestCase {
    func testRoundTrip() {
        let packet = VideoPacket(isKeyframe: true,
                                 parameterSets: [Data([0x67, 1, 2, 3]), Data([0x68, 9])],
                                 payload: Data((0..<10_000).map { UInt8($0 % 251) }))
        let decoded = VideoPacket(data: packet.serialized())
        XCTAssertEqual(decoded?.isKeyframe, true)
        XCTAssertEqual(decoded?.parameterSets, packet.parameterSets)
        XCTAssertEqual(decoded?.payload, packet.payload)

        let delta = VideoPacket(isKeyframe: false, parameterSets: [], payload: Data([1, 2, 3]))
        let decodedDelta = VideoPacket(data: delta.serialized())
        XCTAssertEqual(decodedDelta?.isKeyframe, false)
        XCTAssertEqual(decodedDelta?.parameterSets.count, 0)
    }

    func testMalformedPacketsAreRejectedSafely() {
        XCTAssertNil(VideoPacket(data: Data()))
        XCTAssertNil(VideoPacket(data: Data([1])))
        XCTAssertNil(VideoPacket(data: Data([1, 1, 0xFF, 0xFF, 1, 2])), "宣告長度超過實際資料時不可越界")
        XCTAssertNil(VideoPacket(data: Data([1, 3, 0, 1, 7])), "參數集數量不足時應回傳 nil")
        // 隨機雜訊不應造成當機
        for _ in 0..<2000 {
            let noise = Data((0..<Int.random(in: 0...64)).map { _ in UInt8.random(in: 0...255) })
            _ = VideoPacket(data: noise)
        }
    }
}
