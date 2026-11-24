// FakeMac — 模擬一台 Mac 的 agent，用來對 iPad App 做端對端 / UI 自動化測試
//
// • 使用與真正 Mac agent 相同的加密連線、協定與 H.264 編碼器
// • 畫出一個模擬桌面並串流，畫面上即時顯示收到的游標、點擊、文字、輸入法
// • 每個收到的操作都會以 notice 回傳給 iPad（UI 測試據此驗證）
// • 在 iPad 輸入 "SLEEP" → 模擬 Mac 進入睡眠（斷線並停止監聽）
//   收到正確的 Wake-on-LAN 魔術封包 → 被喚醒並恢復監聽
//
// 用法：FakeMac --code XXXXX-XXXXX-XXXXX-XXXXX [--port 52890] [--wake-port 9]

import Foundation
import Network
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String, _ fallback: String) -> String {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}

let code = arg("--code", "TESTA-BCDEF-GHJKM-NPQRS")
let port = UInt16(arg("--port", "52890"))!
let wakePort = UInt16(arg("--wake-port", "9"))!
let fakeMAC = "AA:BB:CC:DD:EE:01"
let width = 1440, height = 900

func log(_ s: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(t)] \(s)")
}

final class FakeMac {
    let q = DispatchQueue(label: "fakemac")
    var listener: NWListener?
    var wakeListener: NWListener?
    var channel: MessageChannel?
    var encoder: H264Encoder?
    var frameTimer: DispatchSourceTimer?

    var cursor = CGPoint(x: 720, y: 450)
    var lastClick: (point: CGPoint, time: Date, right: Bool)?
    var typed = ""
    var sleeping = false
    var justWoke = false
    var quality = "平衡"
    var sources = [
        InputSourceInfo(id: "com.apple.keylayout.ABC", name: "ABC", isSelected: true),
        InputSourceInfo(id: "com.apple.inputmethod.TCIM.Zhuyin", name: "注音", isSelected: false),
        InputSourceInfo(id: "com.apple.inputmethod.Kotoeri.Japanese", name: "日文", isSelected: false),
    ]
    var currentSource: String { sources.first(where: \.isSelected)?.name ?? "-" }
    /// 與真正的 Mac agent 相同：配對成功後發給 iPad 專屬金鑰（這裡不更換配對碼，方便重複執行測試）
    var pairedKeys: [String: Data] = [:]
    var identified: ObjectIdentifier?

    func start() {
        startListener()
        startWakeListener()
    }

    // MARK: TCP（加密）

    func startListener() {
        listener?.cancel()
        let credentials = [PSKCredential.pairing(code)] + pairedKeys.map { PSKCredential.device(id: $0.key, key: $0.value) }
        let params = SecureTransport.parameters(credentials: credentials)
        params.allowLocalEndpointReuse = true
        let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: "模擬 Mac", type: RemoteConstants.bonjourType,
                                              domain: nil, txtRecord: NWTXTRecord(["id": "fake-mac", "v": "1"]))
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { log("🟢 監聽中（TCP \(port)，ECDHE-PSK 加密，已配對 \(self.pairedKeys.count) 台）") }
            if case .failed(let e) = state {
                // 舊的監聽可能還沒釋放連接埠（例如配對後立即換金鑰重新監聽）：稍後重試
                log("❌ 監聽失敗：\(e)，稍後重試")
                self.q.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.listener === listener else { return }
                    self.startListener()
                }
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: q)
        self.listener = listener
    }

    func accept(_ connection: NWConnection) {
        channel?.connection.cancel()
        let channel = MessageChannel(connection: connection)
        self.channel = channel
        channel.onControl = { [weak self, weak channel] data in
            guard let self, let channel, let m = try? JSONDecoder().decode(ClientMessage.self, from: data) else { return }
            self.handle(m, channel)
        }
        channel.onReceiveError = { _ in log("🔌 連線中斷") }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: log("🔐 iPad 已完成加密交握"); channel.startReceiving()
            case .failed(let e): log("⛔️ 連線失敗：\(e)")
            default: break
            }
        }
        connection.start(queue: q)
    }

    func notice(_ text: String) {
        log("→ notice: \(text)")
        channel?.send(ServerMessage.notice(text))
    }

    func handle(_ m: ClientMessage, _ ch: MessageChannel) {
        switch m {
        case let .identify(id, proof):
            if let key = pairedKeys[id], let expected = SecureTransport.deviceProof(key: key, connection: ch.connection),
               SecureTransport.constantTimeEqual(expected, proof) {
                identified = ObjectIdentifier(ch)
                log("🪪 已配對的 iPad 證明身分成功（\(id.prefix(8))…）")
            } else {
                log("⚠️ 裝置證明不正確")
            }
        case let .hello(name, _, quality, _):
            log("👋 hello from \(name)，畫質 \(quality.title)")
            if identified != ObjectIdentifier(ch) {
                let id = UUID().uuidString
                let key = PSKCredential.newDeviceKey()
                pairedKeys[id] = key
                ch.send(ServerMessage.paired(deviceID: id, key: key))
                log("🔑 新配對：發給 iPad 專屬金鑰")
                startListener()
            }
            ch.send(ServerMessage.hello(HostInfo(
                hostID: "fake-mac", computerName: "模擬 Mac", model: "Mac16,1", isLaptop: true,
                macAddress: fakeMAC, otherMACAddresses: nil, ipv4: "127.0.0.1", broadcast: "127.255.255.255",
                addresses: ["192.0.2.77", "127.0.0.1"],
                displays: [DisplayInfo(id: 1, name: "內建 Retina 顯示器", width: width, height: height, isMain: true)],
                inputSources: sources)))
            ch.send(ServerMessage.permissions(screenRecording: true, accessibility: true))
            startVideo()
            ch.send(ServerMessage.streamStarted(displayID: 1, pixelWidth: width, pixelHeight: height))
            if justWoke {
                justWoke = false
                q.asyncAfter(deadline: .now() + 0.5) { self.notice("⏰ 已被喚醒並重新連線") }
            }
        case .ping(let id):
            ch.send(ServerMessage.pong(id: id))
        case let .mouseMove(x, y):
            cursor = CGPoint(x: x * Double(width), y: y * Double(height))
        case let .mouseMoveRelative(dx, dy):
            cursor.x = min(max(cursor.x + dx * Double(width), 0), Double(width))
            cursor.y = min(max(cursor.y + dy * Double(height), 0), Double(height))
        case let .click(button, count, mods):
            lastClick = (cursor, Date(), button == .right)
            let pct = "\(Int(cursor.x / Double(width) * 100))%, \(Int(cursor.y / Double(height) * 100))%"
            notice(button == .right ? "🖱 右鍵點擊（\(pct)）"
                                    : "🖱 左鍵點擊 ×\(count)\(symbols(mods))（\(pct)）")
        case let .mouseButton(button, down, _, _):
            log("🖱 \(button) \(down ? "按下" : "放開")")
            if !down { notice("🖱 拖曳完成") }
        case let .scroll(dx, dy):
            log("🖱 捲動 dx=\(Int(dx)) dy=\(Int(dy))")
        case let .key(code, down, mods):
            log("⌨️ 實體鍵 0x\(String(code, radix: 16)) \(down ? "↓" : "↑") \(symbols(mods))")
        case let .keyPress(code, mods):
            if code == MacKey.delete, !typed.isEmpty { typed.removeLast() }
            notice("⌨️ 按鍵：\(symbols(mods))\(keyName(code))")
        case let .text(text, paste):
            typed += text
            log("⌨️ 文字\(paste ? "（貼上）" : "")：\(text)")
            if typed.hasSuffix("SLEEP") {
                typed = String(typed.dropLast(5))
                q.asyncAfter(deadline: .now() + 0.3) { self.goToSleep() }
            } else {
                notice("⌨️ 已輸入：\(typed.suffix(40))")
            }
        case let .selectInputSource(id):
            for i in sources.indices { sources[i].isSelected = sources[i].id == id }
            ch.send(ServerMessage.inputSources(sources))
            notice("🌐 輸入法已切換：\(currentSource)")
        case .nextInputSource:
            let i = sources.firstIndex(where: \.isSelected) ?? 0
            for j in sources.indices { sources[j].isSelected = j == (i + 1) % sources.count }
            ch.send(ServerMessage.inputSources(sources))
            notice("🌐 輸入法已切換：\(currentSource)")
        case .selectDisplay(let id):
            log("🖥 選擇螢幕 \(id)")
        case .setQuality(let q):
            quality = q.title
            notice("🎞 畫質：\(q.title)")
        case .requestKeyframe:
            encoder?.requestKeyframe()
        case .wakeDisplay:
            notice("☀️ 螢幕已喚醒")
        case .videoAck:
            break
        case .setInterfaceScale(let scale):
            notice("🔍 介面大小：\(scale.title)")
        case .setAudio(let enabled):
            log(enabled ? "🔊 iPad 開啟聲音" : "🔇 iPad 關閉聲音")
        case .goodbye:
            log("👋 iPad 結束連線")
            ch.connection.cancel()
        }
    }

    // MARK: 睡眠 / 喚醒

    func goToSleep() {
        log("💤 模擬 Mac 進入睡眠：中斷連線、停止監聽，等待 Wake-on-LAN…")
        sleeping = true
        frameTimer?.cancel(); frameTimer = nil
        channel?.connection.cancel(); channel = nil
        listener?.cancel(); listener = nil
    }

    func startWakeListener() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: wakePort)!) else {
            log("⚠️ 無法監聽 UDP \(wakePort)（喚醒測試將失敗）"); return
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: self!.q)
            func receive() {
                c.receiveMessage { data, _, _, error in
                    if let data { self?.gotUDP(data) }
                    if error == nil { receive() }
                }
            }
            receive()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { log("🟢 等待喚醒封包（UDP \(wakePort)）") } }
        listener.start(queue: q)
        wakeListener = listener
    }

    func gotUDP(_ data: Data) {
        let bytes = [UInt8](data)
        let mac = fakeMAC.split(separator: ":").map { UInt8($0, radix: 16)! }
        let valid = bytes.count == 102 && bytes.prefix(6).allSatisfy { $0 == 0xFF }
            && (0..<16).allSatisfy { Array(bytes[(6 + $0 * 6)..<(12 + $0 * 6)]) == mac }
        guard valid else { log("UDP 封包（非本機魔術封包，略過）"); return }
        guard sleeping else { return }
        log("⏰ 收到正確的 Wake-on-LAN 魔術封包，醒來！")
        sleeping = false
        justWoke = true
        q.asyncAfter(deadline: .now() + 1) { self.startListener() }
    }

    // MARK: 影像

    func startVideo() {
        guard frameTimer == nil else { encoder?.requestKeyframe(); return }
        encoder = H264Encoder(width: width, height: height, fps: 30, bitRate: 4_000_000)
        encoder?.onPacket = { [weak self] packet in
            guard let self else { return }
            self.q.async { self.channel?.sendVideo(packet.serialized()) }
        }
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: 1.0 / 20)
        var frame: Int64 = 0
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.channel, channel.pendingVideoSends < 3 else { return }
            frame += 1
            self.encoder?.encode(self.renderFrame(), presentationTime: CMTime(value: frame, timescale: 20))
        }
        timer.resume()
        frameTimer = timer
    }

    func renderFrame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // 翻轉成左上角為原點（與 Mac 螢幕座標一致）
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)

        // 桌布
        let gradient = CGGradient(colorsSpace: nil, colors: [
            CGColor(red: 0.20, green: 0.32, blue: 0.75, alpha: 1), CGColor(red: 0.55, green: 0.25, blue: 0.65, alpha: 1),
            CGColor(red: 0.95, green: 0.55, blue: 0.40, alpha: 1)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        // 選單列
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.75))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 30))
        text("   模擬 Mac    檔案    編輯    顯示方式", at: CGPoint(x: 10, y: 21), size: 15, ctx)
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        text("\(currentSource)    \(clock)", at: CGPoint(x: width - 260, y: 21), size: 15, ctx)

        // 視窗
        let win = CGRect(x: 220, y: 150, width: 1000, height: 560)
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: CGColor(gray: 0, alpha: 0.4))
        ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        for (i, c) in [(1.0, 0.37, 0.33), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: win.minX + 18 + CGFloat(i) * 22, y: win.minY + 16, width: 13, height: 13))
        }
        text("備忘錄 — 遠端輸入測試", at: CGPoint(x: win.midX - 110, y: win.minY + 28), size: 15, ctx, gray: 0.35)
        text("輸入法：\(currentSource)    畫質：\(quality)", at: CGPoint(x: win.minX + 40, y: win.minY + 90), size: 20, ctx, gray: 0.4)
        let shown = typed.isEmpty ? "（在 iPad 上打字，文字會出現在這裡）" : String(typed.suffix(36))
        text(shown + (Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? "|" : ""),
             at: CGPoint(x: win.minX + 40, y: win.minY + 170), size: 40, ctx, gray: typed.isEmpty ? 0.6 : 0.1)

        // 點擊漣漪
        if let click = lastClick, Date().timeIntervalSince(click.time) < 0.8 {
            let r = 20 + Date().timeIntervalSince(click.time) * 60
            ctx.setStrokeColor(click.right ? CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.9) : CGColor(red: 0, green: 0.5, blue: 1, alpha: 0.9))
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: click.point.x - r, y: click.point.y - r, width: r * 2, height: r * 2))
        }
        // 游標
        let p = cursor
        let arrow = CGMutablePath()
        arrow.move(to: p); arrow.addLine(to: CGPoint(x: p.x, y: p.y + 26))
        arrow.addLine(to: CGPoint(x: p.x + 7, y: p.y + 20)); arrow.addLine(to: CGPoint(x: p.x + 12, y: p.y + 30))
        arrow.addLine(to: CGPoint(x: p.x + 16, y: p.y + 28)); arrow.addLine(to: CGPoint(x: p.x + 11, y: p.y + 18))
        arrow.addLine(to: CGPoint(x: p.x + 19, y: p.y + 18)); arrow.closeSubpath()
        ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
        ctx.addPath(arrow); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.5); ctx.strokePath()
        return pb
    }

    func text(_ s: String, at p: CGPoint, size: CGFloat, _ ctx: CGContext, gray: CGFloat = 0.1) {
        let font = CTFontCreateUIFontForLanguage(.system, size, "zh-Hant" as CFString)!
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

func symbols(_ m: Modifiers) -> String {
    (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") +
    (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
}

func keyName(_ code: UInt16) -> String {
    [MacKey.escape: "esc", MacKey.tab: "tab", MacKey.returnKey: "return", MacKey.delete: "delete",
     MacKey.space: "space", MacKey.left: "←", MacKey.right: "→", MacKey.up: "↑", MacKey.down: "↓",
     MacKey.c: "C", MacKey.v: "V", MacKey.q: "Q", MacKey.w: "W", MacKey.a: "A", MacKey.z: "Z"][code]
        ?? "0x" + String(code, radix: 16)
}

let mac = FakeMac()
mac.start()
log("FakeMac 啟動，配對碼 \(code)，MAC \(fakeMAC)")
dispatchMain()
