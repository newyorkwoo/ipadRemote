import Foundation
import Darwin

/// 把兩個檔案描述元（socket / pipe）雙向對接：內嵌 Tailscale 的連線 ↔ 本機 TCP。
/// 加密（TLS-PSK）仍在兩端 App 之間端對端進行，這裡只搬運密文，不解讀內容。
enum TCPBridge {
    private static let bufferSize = 256 * 1024

    /// 雙向搬運，任一方向結束（EOF 或錯誤）就關閉兩端；結束後呼叫 onClose（任意執行緒）
    static func pump(_ a: Int32, _ b: Int32, onClose: (() -> Void)? = nil) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(a, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(b, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let closer = Closer(a, b, onClose: onClose)
        // 每個方向一條執行緒：阻塞式 write 天然提供背壓，網路慢時不會在記憶體裡越積越多
        for (from, to) in [(a, b), (b, a)] {
            let thread = Thread {
                copy(from: from, to: to)
                closer.close()
            }
            thread.name = "ipadremote.bridge"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private static func copy(from: Int32, to: Int32) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(from, buffer, bufferSize)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            var offset = 0
            while offset < n {
                let w = write(to, buffer + offset, n - offset)
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { return }
                offset += w
            }
        }
    }

    /// 兩個方向共用：先結束的一方關閉兩端，讓另一個方向的阻塞 read 立即返回
    private final class Closer {
        private let lock = NSLock()
        private var fds: (Int32, Int32)?
        private let onClose: (() -> Void)?

        init(_ a: Int32, _ b: Int32, onClose: (() -> Void)?) {
            fds = (a, b)
            self.onClose = onClose
        }

        func close() {
            lock.lock()
            let pair = fds
            fds = nil
            lock.unlock()
            guard let (a, b) = pair else { return }
            // shutdown 會喚醒另一條卡在 read 的執行緒；pipe 不支援 shutdown，失敗無妨
            _ = shutdown(a, SHUT_RDWR)
            _ = shutdown(b, SHUT_RDWR)
            Darwin.close(a)
            Darwin.close(b)
            onClose?()
        }
    }
}

/// 只接受一條連線的本機監聽（127.0.0.1、系統分配埠）。
/// iPad 端用它把已經在 tailnet 上建立好的連線交給 NWConnection（TLS 照舊在 NWConnection 裡進行）。
final class OneShotLoopbackListener {
    let port: UInt16
    private var fd: Int32

    /// 綁定 127.0.0.1 的隨機埠；失敗時回傳 nil
    init?() {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 1) == 0 else { Darwin.close(s); return nil }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard named == 0 else { Darwin.close(s); return nil }
        fd = s
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close() }

    /// 等待一條連線（阻塞，最多 timeout 秒），之後不再接受新連線
    func acceptOnce(timeout: TimeInterval) -> Int32? {
        guard fd >= 0 else { return nil }
        defer { close() }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return nil }
        let conn = accept(fd, nil, nil)
        return conn >= 0 ? conn : nil
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

enum LoopbackSocket {
    /// 連到本機 127.0.0.1:port（Mac 端把 tailnet 連線轉給既有的 RemoteServer）
    static func connect(port: UInt16) -> Int32? {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { Darwin.close(s); return nil }
        var one: Int32 = 1
        _ = setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return s
    }
}
