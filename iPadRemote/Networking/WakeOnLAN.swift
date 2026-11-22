import Foundation
import Darwin

/// Wake-on-LAN 魔術封包：6 × 0xFF + 16 × MAC 位址
///
/// 送出目標：
/// 1. 255.255.255.255 與子網路廣播位址（同一個區網時最可靠；iOS 需要 multicast entitlement）
/// 2. Mac 最後已知的 IP（單播，路由器 ARP 快取仍在時有效）
/// 3. 使用者設定的外部喚醒位址（路由器 UDP 轉發到區網廣播，從外部網路喚醒用）
enum WakeOnLAN {
    struct Target: Hashable {
        var host: String
        var port: UInt16
    }

    static func magicPacket(for mac: String) -> Data? {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    static func targets(for device: SavedMac) -> [Target] {
        var targets: [Target] = [Target(host: "255.255.255.255", port: 9)]
        if let broadcast = device.lastBroadcast { targets.append(Target(host: broadcast, port: 9)) }
        if let ip = device.lastIPv4 { targets.append(Target(host: ip, port: 9)) }
        let wakeHost = device.wakeHost.trimmingCharacters(in: .whitespaces)
        if !wakeHost.isEmpty {
            targets.append(Target(host: wakeHost, port: device.wakePort))
        }
        return Array(Set(targets))
    }

    /// 每個已知的 MAC 都送一份（Wi‑Fi 私密位址與硬體位址可能不同）
    static func packets(for device: SavedMac) -> [Data] {
        var macs = [device.macAddress] + (device.otherMACAddresses ?? [])
        macs = macs.filter { !$0.isEmpty }
        var seen = Set<String>()
        return macs.compactMap { mac in
            let key = mac.uppercased().filter(\.isHexDigit)
            guard seen.insert(key).inserted else { return nil }
            return magicPacket(for: mac)
        }
    }

    /// 在背景執行緒送出，完成後於主執行緒回報成功送出的目標數
    static func wake(_ device: SavedMac, completion: ((Int) -> Void)? = nil) {
        let packets = packets(for: device)
        guard !packets.isEmpty else {
            completion?(0)
            return
        }
        let targets = targets(for: device)
        DispatchQueue.global(qos: .userInitiated).async {
            let count = packets.map { send($0, to: targets) }.max() ?? 0
            DispatchQueue.main.async { completion?(count) }
        }
    }

    private static func send(_ packet: Data, to targets: [Target]) -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var succeeded = 0
        for target in targets {
            var ok = false
            for var address in resolve(target) {
                for _ in 0..<3 {
                    let result = packet.withUnsafeBytes { raw in
                        withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, raw.baseAddress, packet.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if result >= 0 { ok = true }
                }
            }
            if ok { succeeded += 1 }
        }
        return succeeded
    }

    private static func resolve(_ target: Target) -> [sockaddr_in] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(target.host, String(target.port), &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(result) }
        return sequence(first: first, next: { $0.pointee.ai_next }).compactMap { info in
            guard let addr = info.pointee.ai_addr, info.pointee.ai_family == AF_INET else { return nil }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
    }
}
