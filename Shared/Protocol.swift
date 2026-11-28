import Foundation

/// 兩端共用的常數
enum RemoteConstants {
    static let bonjourType = "_ipadremote._tcp"
    static let defaultPort: UInt16 = 52800
    /// 2：iPad 會回報收到的影像幀（videoAck），Mac 以此限制在途幀數
    /// 3：ECDHE-PSK 前向保密、每台 iPad 專屬裝置金鑰（identify / paired）
    static let protocolVersion = 3
    static let pskIdentity = "iPadRemote-v1"
}

// MARK: - 網路位址工具

enum NetworkAddress {
    /// Tailscale 使用 100.64.0.0/10（CGNAT 範圍）
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func isPrivateLAN(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }
}

// MARK: - 內嵌 Tailscale 的節點命名

/// 兩個 App 內嵌的 Tailscale 節點在 tailnet 上的主機名稱。
/// Mac：ipadremote-mac-<hostID 前 8 碼>-<電腦名稱>，iPad 用前綴辨認 tailnet 上哪些是自己的 Mac。
enum TailnetNaming {
    static let macPrefix = "ipadremote-mac-"
    static let iPadPrefix = "ipadremote-ipad-"

    static func macHostName(computerName: String, hostID: String) -> String {
        let name = sanitize(computerName)
        return macPrefix + idTag(hostID) + (name.isEmpty ? "" : "-" + name)
    }

    static func iPadHostName(deviceName: String) -> String {
        let name = sanitize(deviceName)
        return iPadPrefix + (name.isEmpty ? "ipad" : name)
    }

    /// hostID（UUID）前 8 碼，小寫
    static func idTag(_ hostID: String) -> String {
        String(hostID.lowercased().filter(\.isHexDigit).prefix(8))
    }

    /// 解析 Mac 節點名稱 → (hostID 前 8 碼, 顯示名稱)；不是本 App 的 Mac 節點時回傳 nil
    static func parseMac(_ hostName: String) -> (idTag: String, displayName: String)? {
        let lower = hostName.lowercased()
        guard lower.hasPrefix(macPrefix) else { return nil }
        let rest = lower.dropFirst(macPrefix.count)
        let tag = String(rest.prefix(8))
        guard tag.count == 8, tag.allSatisfy(\.isHexDigit) else { return nil }
        let name = rest.dropFirst(8).drop(while: { $0 == "-" })
            .split(separator: "-").joined(separator: " ")
        return (tag, name.isEmpty ? "Mac" : name)
    }

    static func matches(hostID: String?, idTag tag: String) -> Bool {
        guard let hostID, !tag.isEmpty else { return false }
        return idTag(hostID) == tag
    }

    /// DNS 標籤只能用英數與連字號：中文等字元會被略過；最長 39 字元，整個名稱才不超過 63 字元
    static func sanitize(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(39)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - 共用資料模型

struct InputSourceInfo: Codable, Hashable, Identifiable {
    var id: String          // 例如 com.apple.inputmethod.TCIM.Zhuyin
    var name: String        // 例如「注音」
    var isSelected: Bool
}

extension InputSourceInfo {
    /// 顯示用的中文名稱。Mac 回報的名稱依 Mac 端程式的語系而定，常是英文（例如「Zhuyin - Traditional」），
    /// 常見的輸入法改用固定的中文名稱；不認得的維持 Mac 給的名稱
    var displayName: String { Self.chineseName(forID: id) ?? name }

    static func chineseName(forID id: String) -> String? {
        let parts = id.split(separator: ".").map(String.init)
        guard let last = parts.last else { return nil }
        if id.hasPrefix("com.apple.inputmethod.TCIM.") {
            switch last {
            case "Zhuyin": return "注音"
            case "ZhuyinEten": return "注音（倚天）"
            case "Cangjie": return "倉頡"
            case "Jianyi": return "速成"
            case "Pinyin": return "拼音（繁體）"
            case "Shuangpin": return "雙拼（繁體）"
            case "WBH": return "筆畫（繁體）"
            default: return nil
            }
        }
        if id.hasPrefix("com.apple.inputmethod.SCIM.") {
            switch last {
            case "ITABC": return "拼音（簡體）"
            case "Shuangpin": return "雙拼（簡體）"
            case "WBX", "WBXFull": return "五筆"
            case "WBH": return "筆畫（簡體）"
            default: return nil
            }
        }
        if id.hasPrefix("com.apple.inputmethod.TYIM.") { return "粵語" }
        if id.hasPrefix("com.apple.inputmethod.Kotoeri.") {
            if last.contains("Katakana") { return "片假名" }
            if last.contains("Japanese") { return "日文" }
            return nil
        }
        if id.hasPrefix("com.apple.inputmethod.Korean.") { return "韓文" }
        if id.hasPrefix("com.apple.keylayout.") {
            switch last {
            case "ABC": return "ABC"
            case "US": return "英文（美式）"
            case "British": return "英文（英式）"
            default: return nil
            }
        }
        return nil
    }
}

struct DisplayInfo: Codable, Hashable, Identifiable {
    var id: UInt32
    var name: String
    var width: Int          // 點 (points)
    var height: Int
    var isMain: Bool
}

struct HostInfo: Codable, Hashable {
    var hostID: String
    var computerName: String
    var model: String
    var isLaptop: Bool
    var macAddress: String?
    /// 其他可能的 MAC（例如 Wi‑Fi 私密位址與硬體位址都送）；舊版沒有此欄位
    var otherMACAddresses: [String]? = nil
    var ipv4: String?
    var broadcast: String?
    /// Mac 所有可連入的 IPv4（區網 + Tailscale 等 VPN），讓 iPad 在不同網路時也能自動找到路
    var addresses: [String]? = nil
    var displays: [DisplayInfo]
    var inputSources: [InputSourceInfo]
}

enum MouseButton: String, Codable {
    case left, right, middle
}

struct Modifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8
    static let command  = Modifiers(rawValue: 1 << 0)
    static let option   = Modifiers(rawValue: 1 << 1)
    static let control  = Modifiers(rawValue: 1 << 2)
    static let shift    = Modifiers(rawValue: 1 << 3)
    static let function = Modifiers(rawValue: 1 << 4)
}

enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case low, balanced, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "省流量"
        case .balanced: return "平衡"
        case .high: return "高畫質"
        }
    }
    var maxPixelWidth: Int {
        switch self {
        case .low: return 1280
        case .balanced: return 1920
        case .high: return 2880
        }
    }
    /// 所有畫質都以每秒 60 張更新，畫質差別只在解析度與位元率
    var framesPerSecond: Int { 60 }
    var bitRate: Int {
        switch self {
        case .low: return 4_000_000
        case .balanced: return 8_000_000
        case .high: return 16_000_000
        }
    }
}

/// 串流期間把 Mac 螢幕暫時切到較低的「看起來像」解析度，讓文字與介面在 iPad 上變大（斷線後還原）
enum InterfaceScale: String, Codable, CaseIterable, Identifiable {
    case native, large, larger, largest
    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "原始大小"
        case .large: return "大"
        case .larger: return "較大"
        case .largest: return "最大"
        }
    }
    /// 目標的「看起來像」寬度（點）；iPad 13 吋橫放約 1376 點寬
    var targetWidth: Int? {
        switch self {
        case .native: return nil
        case .large: return 1920
        case .larger: return 1600
        case .largest: return 1280
        }
    }
}

// MARK: - 訊息

/// iPad → Mac
enum ClientMessage: Codable {
    /// 已配對的 iPad 在 hello 之前送出，證明自己持有哪一把裝置金鑰；沒送的連線視為「用配對碼進行新配對」
    case identify(deviceID: String, proof: Data)
    case hello(clientName: String, protocolVersion: Int, quality: StreamQuality, displayID: UInt32?)
    case ping(id: UInt64)
    /// 絕對座標，0...1 正規化於目前串流的螢幕
    case mouseMove(x: Double, y: Double)
    /// 相對位移，以螢幕寬高為 1 的正規化單位
    case mouseMoveRelative(dx: Double, dy: Double)
    case mouseButton(button: MouseButton, down: Bool, clickCount: Int, modifiers: Modifiers)
    case click(button: MouseButton, clickCount: Int, modifiers: Modifiers)
    case scroll(dx: Double, dy: Double)
    case key(keyCode: UInt16, down: Bool, modifiers: Modifiers)
    case keyPress(keyCode: UInt16, modifiers: Modifiers)
    case text(String, usePaste: Bool)
    case selectInputSource(id: String)
    case nextInputSource
    /// 在 Mac 的注音與 ABC 英文鍵盤之間切換（英文用純 ABC，不會變成全形）
    case toggleChineseEnglish
    case selectDisplay(id: UInt32)
    case setQuality(StreamQuality)
    case requestKeyframe
    /// 收到幾張影像幀（流量控制：Mac 限制尚未被確認的幀數，避免網路緩衝塞滿造成延遲）
    case videoAck(count: Int)
    /// 開關 Mac 聲音轉送到 iPad
    case setAudio(enabled: Bool)
    /// 調整 Mac 螢幕解析度讓介面變大（舊版 Mac 端會忽略）
    case setInterfaceScale(InterfaceScale)
    case wakeDisplay
    case goodbye
}

/// Mac → iPad
enum ServerMessage: Codable {
    case hello(HostInfo)
    case pong(id: UInt64)
    case inputSources([InputSourceInfo])
    case streamStarted(displayID: UInt32, pixelWidth: Int, pixelHeight: Int)
    case permissions(screenRecording: Bool, accessibility: Bool)
    case notice(String)
    /// 新配對完成：Mac 發給這台 iPad 的專屬金鑰，之後連線改用它（配對碼隨即失效）
    case paired(deviceID: String, key: Data)
}

// MARK: - Mac 虛擬鍵碼（對應 Carbon kVK_*）

enum MacKey {
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let delete: UInt16 = 0x33
    static let escape: UInt16 = 0x35
    static let command: UInt16 = 0x37
    static let shift: UInt16 = 0x38
    static let capsLock: UInt16 = 0x39
    static let option: UInt16 = 0x3A
    static let control: UInt16 = 0x3B
    static let rightCommand: UInt16 = 0x36
    static let rightShift: UInt16 = 0x3C
    static let rightOption: UInt16 = 0x3D
    static let rightControl: UInt16 = 0x3E
    static let function: UInt16 = 0x3F
    static let forwardDelete: UInt16 = 0x75
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    static let left: UInt16 = 0x7B
    static let right: UInt16 = 0x7C
    static let down: UInt16 = 0x7D
    static let up: UInt16 = 0x7E
    static let eisu: UInt16 = 0x66
    static let kana: UInt16 = 0x68
    static let f1: UInt16 = 0x7A, f2: UInt16 = 0x78, f3: UInt16 = 0x63, f4: UInt16 = 0x76
    static let f5: UInt16 = 0x60, f6: UInt16 = 0x61, f7: UInt16 = 0x62, f8: UInt16 = 0x64
    static let f9: UInt16 = 0x65, f10: UInt16 = 0x6D, f11: UInt16 = 0x67, f12: UInt16 = 0x6F
    static let a: UInt16 = 0x00, c: UInt16 = 0x08, q: UInt16 = 0x0C, v: UInt16 = 0x09
    static let w: UInt16 = 0x0D, z: UInt16 = 0x06

    static let modifierKeys: [UInt16: Modifiers] = [
        command: .command, rightCommand: .command,
        shift: .shift, rightShift: .shift,
        option: .option, rightOption: .option,
        control: .control, rightControl: .control,
        function: .function,
    ]
}
