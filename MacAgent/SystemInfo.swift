import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

enum SystemInfo {
    static var computerName: String {
        Host.current().localizedName ?? "Mac"
    }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var isLaptop: Bool { model.contains("Book") }

    struct NetworkInterface {
        var name: String
        /// 主要喚醒用 MAC（目前在網路上使用中的位址）
        var mac: String?
        /// 所有可能的 MAC：使用中的（可能是 Wi‑Fi 私密位址）+ 硬體位址
        var allMACs: [String] = []
        var ipv4: String?
        var broadcast: String?
    }

    /// macOS 對一般 API 回傳的隱私佔位位址，不能用於 Wake-on-LAN
    static let placeholderMAC = "02:00:00:00:00:00"

    /// 硬體（燒錄）MAC，透過 IOKit 讀取
    static func hardwareMAC(for bsdName: String) -> String? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var controller: io_object_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &controller) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(controller) }
        guard let data = IORegistryEntryCreateCFProperty(controller, "IOMACAddress" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
              data.count == 6 else { return nil }
        return formatMAC(Array(data))
    }

    /// 目前使用中的 MAC（Wi‑Fi「私密 Wi‑Fi 位址」開啟時與硬體位址不同），由 ifconfig 讀取
    static func activeMAC(for bsdName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [bsdName, "ether"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = output.range(of: #"ether ([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5})"#, options: .regularExpression) else {
            return nil
        }
        let mac = output[range].dropFirst("ether ".count).uppercased()
        return mac == placeholderMAC ? nil : mac
    }

    private static func formatMAC(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 取得主要網路介面（en0 / en1…）的 MAC、IPv4 與廣播位址，供 iPad 送 Wake-on-LAN
    static func primaryInterface() -> NetworkInterface? {
        var interfaces: [String: NetworkInterface] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), let addr = ifa.ifa_addr else { continue }
            var info = interfaces[name] ?? NetworkInterface(name: name)

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                    let nameLength = Int(sdl.pointee.sdl_nlen)
                    guard sdl.pointee.sdl_alen == 6 else { return }
                    let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!
                    let base = UnsafeRawPointer(sdl).advanced(by: offset + nameLength)
                    let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                    let mac = formatMAC(bytes)
                    if mac != placeholderMAC { info.mac = mac }
                }
            case AF_INET:
                info.ipv4 = ipString(addr)
                if let mask = ifa.ifa_netmask, let ip = info.ipv4, let maskString = ipString(mask) {
                    info.broadcast = broadcastAddress(ip: ip, mask: maskString)
                }
            default:
                break
            }
            interfaces[name] = info
        }
        // 優先選有 IPv4 的介面，再依名稱排序（en0 通常是乙太網路或內建 Wi-Fi）
        guard var primary = interfaces.values
            .sorted(by: { ($0.ipv4 != nil ? 0 : 1, $0.name) < ($1.ipv4 != nil ? 0 : 1, $1.name) })
            .first else { return nil }

        // 新版 macOS 的 getifaddrs 只回傳 02:00:00:00:00:00，改從 ifconfig 與 IOKit 取得真正的位址
        var macs: [String] = []
        for candidate in [activeMAC(for: primary.name), primary.mac, hardwareMAC(for: primary.name)] {
            if let mac = candidate, mac != placeholderMAC, !macs.contains(mac) { macs.append(mac) }
        }
        primary.allMACs = macs
        primary.mac = macs.first
        return primary
    }

    /// 所有可從 iPad 連入的 IPv4：區網介面 (en*) 與 VPN 介面 (utun*，例如 Tailscale)
    static func reachableIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun"),
                  let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let ip = ipString(addr), !ip.hasPrefix("169.254."), !result.contains(ip) else { continue }
            // VPN 介面只收 Tailscale 位址，避免把公司 VPN 等無關位址告訴 iPad
            if name.hasPrefix("utun") && !NetworkAddress.isTailscale(ip) { continue }
            result.append(ip)
        }
        return result
    }

    static var tailscaleIPv4: String? {
        reachableIPv4Addresses().first(where: NetworkAddress.isTailscale)
    }

    private static func ipString(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    private static func broadcastAddress(ip: String, mask: String) -> String? {
        var ipAddr = in_addr(), maskAddr = in_addr()
        guard inet_pton(AF_INET, ip, &ipAddr) == 1, inet_pton(AF_INET, mask, &maskAddr) == 1 else { return nil }
        var bcast = in_addr(s_addr: ipAddr.s_addr | ~maskAddr.s_addr)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &bcast, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(id: id, name: screen.localizedName,
                               width: Int(screen.frame.width), height: Int(screen.frame.height),
                               isMain: id == CGMainDisplayID())
        }
    }
}

/// 電源管理：連線期間防止 Mac 閒置睡眠、喚醒螢幕
final class PowerManager {
    private var sleepAssertion: IOPMAssertionID = 0
    private var userActivityAssertion: IOPMAssertionID = 0
    private var standbyAssertion: IOPMAssertionID = 0

    /// 遠端待命：系統不睡眠（螢幕仍可關閉），讓 iPad 從任何網路都能連進來。
    /// macOS 只在接電源時遵守此設定；MacBook 闔上蓋子（未接外接螢幕）仍會睡眠。
    func setStandby(_ enabled: Bool) {
        if enabled, standbyAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "iPad Remote 遠端待命" as CFString,
                                        &standbyAssertion)
        } else if !enabled, standbyAssertion != 0 {
            IOPMAssertionRelease(standbyAssertion)
            standbyAssertion = 0
        }
    }

    var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    func preventIdleSleep(_ enabled: Bool) {
        if enabled, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "iPad 遠端控制連線中" as CFString,
                                        &sleepAssertion)
        } else if !enabled, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    /// 模擬使用者活動，讓已關閉的螢幕亮起
    func wakeDisplay() {
        IOPMAssertionDeclareUserActivity("iPad 遠端控制" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)
    }
}
