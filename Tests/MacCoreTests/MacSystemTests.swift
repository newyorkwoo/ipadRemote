import XCTest
import CoreGraphics
import CoreMedia
import VideoToolbox

/// H.264：Mac 編碼 → 封包 → 解碼，確認畫面能正確還原
final class H264RoundTripTests: XCTestCase {
    private func makePixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * bytesPerRow + x * 4
                p[0] = UInt8((x + Int(shade)) % 256); p[1] = UInt8(y % 256); p[2] = shade; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    func testEncodeThenDecodeAllFrames() throws {
        let width = 640, height = 400, frames = 30
        let encoder = try XCTUnwrap(H264Encoder(width: width, height: height, fps: 30, bitRate: 2_000_000))
        let lock = NSLock()
        var packets: [VideoPacket] = []
        let encoded = expectation(description: "encoded")
        encoded.expectedFulfillmentCount = frames + 1
        encoder.onPacket = { packet in
            // 走一次實際的序列化 / 反序列化
            let wire = VideoPacket(data: packet.serialized())!
            lock.withLock { packets.append(wire) }
            encoded.fulfill()
        }
        for i in 0..<frames {
            encoder.encode(makePixelBuffer(width: width, height: height, shade: UInt8(i * 8)),
                           presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        // 要求關鍵幀（例如 iPad 重新連線時）
        Thread.sleep(forTimeInterval: 0.5)
        encoder.requestKeyframe()
        encoder.encode(makePixelBuffer(width: width, height: height, shade: 1),
                       presentationTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        wait(for: [encoded], timeout: 10)

        XCTAssertTrue(packets.first!.isKeyframe, "第一幀必須是關鍵幀")
        XCTAssertGreaterThanOrEqual(packets.first!.parameterSets.count, 2, "關鍵幀要帶 SPS/PPS")
        XCTAssertTrue(packets.last!.isKeyframe, "requestKeyframe 後的下一幀必須是關鍵幀")
        XCTAssertTrue(packets.dropFirst().dropLast().contains { !$0.isKeyframe }, "中間應為差異幀（省頻寬）")

        // 解碼
        let sets = packets.first!.parameterSets
        var format: CMFormatDescription?
        try sets[0].withUnsafeBytes { sps in
            try sets[1].withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sets[0].count, sets[1].count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
                XCTAssertEqual(status, noErr)
                if status != noErr { throw NSError(domain: "fmt", code: Int(status)) }
            }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format!)
        XCTAssertEqual(Int(dims.width), width)
        XCTAssertEqual(Int(dims.height), height)

        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!,
                                                    decoderSpecification: nil, imageBufferAttributes: nil,
                                                    outputCallback: nil, decompressionSessionOut: &session), noErr)
        var decoded = 0
        for packet in packets {
            var block: CMBlockBuffer?
            let data = packet.payload
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                               blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                               dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                               blockBufferOut: &block)
            data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                                     offsetIntoDestination: 0, dataLength: data.count) }
            var sample: CMSampleBuffer?
            var size = data.count
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                      sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image, CVPixelBufferGetWidth(image) == width { decoded += 1 }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        XCTAssertEqual(decoded, packets.count, "每一個封包都應成功解碼")
    }
}

/// 滑鼠鍵盤注入：攔截 CGEvent 檢查內容（不會真的移動你的游標或打字）
final class InputInjectorTests: XCTestCase {
    private var events: [CGEvent] = []
    private var activations: [CGPoint] = []
    private var injector: InputInjector!
    private let cursor = CGPoint(x: 100, y: 100)

    override func setUp() {
        events = []
        activations = []
        injector = InputInjector()
        injector.displayID = CGMainDisplayID()
        injector.post = { [unowned self] in self.events.append($0) }
        injector.cursorLocation = { [unowned self] in self.cursor }
        injector.activateWindow = { [unowned self] in self.activations.append($0) }
    }

    func testAbsoluteMoveMapsToDisplayCoordinates() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        injector.moveAbsolute(x: 0.5, y: 0.5)
        injector.moveAbsolute(x: -3, y: 9) // 超出範圍應被夾住
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, .mouseMoved)
        XCTAssertEqual(events[0].location.x, bounds.minX + 0.5 * (bounds.width - 1), accuracy: 1)
        XCTAssertEqual(events[0].location.y, bounds.minY + 0.5 * (bounds.height - 1), accuracy: 1)
        XCTAssertEqual(events[1].location.x, bounds.minX, accuracy: 1)
        XCTAssertEqual(events[1].location.y, bounds.maxY - 1, accuracy: 1)
    }

    func testRelativeMove() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        injector.moveRelative(dx: 0.1, dy: 0)
        XCTAssertEqual(events[0].location.x, min(cursor.x + 0.1 * bounds.width, bounds.maxX - 1), accuracy: 1)
    }

    func testDoubleClickWithCommandModifier() {
        injector.click(.left, clickCount: 2, modifiers: .command)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(events[0].getIntegerValueField(.mouseEventClickState), 2)
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        XCTAssertEqual(events[0].location, cursor)
    }

    func testRightClick() {
        injector.click(.right, clickCount: 1, modifiers: [])
        XCTAssertEqual(events.map(\.type), [.rightMouseDown, .rightMouseUp])
    }

    func testLeftClickBringsClickedWindowToFront() {
        // 點到被其他視窗蓋住的視窗時，要先把它升到最前面（在游標位置）
        injector.click(.left, clickCount: 1, modifiers: [])
        XCTAssertEqual(activations, [cursor])
        // 拖曳中不重複處理；右鍵不升起視窗（和真的滑鼠一樣）
        activations.removeAll()
        injector.button(.left, down: true, clickCount: 1, modifiers: [])
        injector.button(.left, down: true, clickCount: 1, modifiers: [])
        injector.button(.left, down: false, clickCount: 1, modifiers: [])
        injector.click(.right, clickCount: 1, modifiers: [])
        XCTAssertEqual(activations.count, 1)
    }

    func testWindowActivatorIgnoresPointsWithoutWindows() {
        // 真實呼叫：螢幕外的點找不到視窗，不應有任何動作或當機
        WindowActivator.bringWindowToFront(at: CGPoint(x: -100_000, y: -100_000))
    }

    func testDragProducesDraggedEventsAndReleaseAllLetsGo() {
        injector.button(.left, down: true, clickCount: 1, modifiers: [])
        injector.moveAbsolute(x: 0.3, y: 0.3)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseDragged])
        // 斷線時不應留下按住的滑鼠鍵
        injector.releaseAll()
        XCTAssertEqual(events.last?.type, .leftMouseUp)
        events.removeAll()
        injector.moveAbsolute(x: 0.4, y: 0.4)
        XCTAssertEqual(events.last?.type, .mouseMoved)
    }

    func testScroll() {
        injector.scroll(dx: 4, dy: -20)
        XCTAssertEqual(events[0].type, .scrollWheel)
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -20)
        XCTAssertEqual(events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 4)
    }

    func testHeldModifierAppliesToFollowingKeysAndIsReleased() {
        injector.key(MacKey.command, down: true, modifiers: [])
        injector.keyPress(MacKey.c, modifiers: [])
        injector.key(MacKey.command, down: false, modifiers: [])
        injector.keyPress(MacKey.c, modifiers: [])
        XCTAssertEqual(events[0].type, .flagsChanged)
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        XCTAssertEqual(events[1].type, .keyDown)
        XCTAssertEqual(events[1].getIntegerValueField(.keyboardEventKeycode), Int64(MacKey.c))
        XCTAssertTrue(events[1].flags.contains(.maskCommand), "按住 ⌘ 時按 C 應為 ⌘C")
        XCTAssertEqual(events[3].type, .flagsChanged)
        XCTAssertFalse(events[4].flags.contains(.maskCommand), "放開 ⌘ 後不應殘留")
    }

    func testStuckModifiersAreReleasedOnDisconnect() {
        injector.key(MacKey.shift, down: true, modifiers: [])
        injector.key(MacKey.option, down: true, modifiers: [])
        events.removeAll()
        injector.releaseAll()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.type == .flagsChanged })
        XCTAssertEqual(events.last?.flags.contains(.maskShift), false)
        XCTAssertEqual(events.last?.flags.contains(.maskAlternate), false)
    }

    func testUnicodeTextIncludingChineseAndEmojiIsTypedExactly() {
        let text = "你好，世界！ABC 注音ㄅㄆㄇ 日本語 🙂👍🏽 " + String(repeating: "長", count: 40)
        injector.type(text)
        var typed: [UniChar] = []
        for event in events where event.type == .keyDown {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 32)
            event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertLessThanOrEqual(length, 16)
            if length > 0 {
                XCTAssertFalse(UTF16.isLeadSurrogate(buffer[length - 1]), "不可把 emoji 切成兩半")
            }
            typed += buffer.prefix(length)
        }
        XCTAssertEqual(String(utf16CodeUnits: typed, count: typed.count), text)
        XCTAssertEqual(events.filter { $0.type == .keyUp }.count, events.filter { $0.type == .keyDown }.count)
    }
}

/// 讀取 Mac 系統資訊（唯讀，不會改變你的設定）
final class MacSystemInfoTests: XCTestCase {
    func testInputSourcesAreListed() {
        let sources = InputSourceManager.list()
        print("Mac 已啟用輸入法：", sources.map { "\($0.name)\($0.isSelected ? "✓" : "")" })
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.contains(where: \.isSelected), "應該有一個目前使用中的輸入法")
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
    }

    func testSelectingCurrentInputSourceSucceeds() {
        // 選擇「目前已選的」輸入法 → 驗證切換 API 可用，但不改變你的狀態
        guard let current = InputSourceManager.list().first(where: \.isSelected) else { return XCTFail() }
        XCTAssertTrue(InputSourceManager.select(id: current.id))
        XCTAssertFalse(InputSourceManager.select(id: "does.not.exist"))
    }

    func testNetworkInfoForWakeOnLAN() throws {
        let net = try XCTUnwrap(SystemInfo.primaryInterface(), "找不到網路介面")
        print("主要介面：", net.name, net.allMACs, net.ipv4 ?? "-", net.broadcast ?? "-")
        let mac = try XCTUnwrap(net.mac)
        XCTAssertNotEqual(mac, SystemInfo.placeholderMAC, "不可回傳隱私佔位 MAC，否則無法喚醒")
        let hardware = try XCTUnwrap(SystemInfo.hardwareMAC(for: net.name), "應能從 IOKit 讀到硬體 MAC")
        XCTAssertTrue(net.allMACs.contains(hardware), "硬體 MAC 必須在喚醒清單中")
        XCTAssertFalse(net.allMACs.contains(SystemInfo.placeholderMAC))
        XCTAssertNotNil(mac.range(of: #"^([0-9A-F]{2}:){5}[0-9A-F]{2}$"#, options: .regularExpression))
        if let ip = net.ipv4, let broadcast = net.broadcast {
            XCTAssertEqual(ip.split(separator: ".").first, broadcast.split(separator: ".").first)
        }
    }

    func testReachableAddressesIncludeLANAndOnlyTailscaleVPN() throws {
        let addresses = SystemInfo.reachableIPv4Addresses()
        print("可連入位址：", addresses, "Tailscale：", SystemInfo.tailscaleIPv4 ?? "未安裝")
        let lan = try XCTUnwrap(SystemInfo.primaryInterface()?.ipv4)
        XCTAssertTrue(addresses.contains(lan))
        XCTAssertFalse(addresses.contains("127.0.0.1"))
        XCTAssertTrue(addresses.allSatisfy { NetworkAddress.isPrivateLAN($0) || NetworkAddress.isTailscale($0) || !$0.hasPrefix("169.254") })
    }

    func testDisplaysAndModel() {
        XCTAssertFalse(SystemInfo.model.isEmpty)
        XCTAssertFalse(SystemInfo.displays().isEmpty)
        XCTAssertEqual(SystemInfo.displays().filter(\.isMain).count, 1)
    }
}
