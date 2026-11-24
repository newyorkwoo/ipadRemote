import Foundation
import Darwin
import CTailscale

/// 在內嵌 Tailscale 節點上監聽，並把每條連線轉給本機的 RemoteServer（127.0.0.1:port）。
/// RemoteServer 不需要任何改動：TLS-PSK 加密、配對與裝置金鑰檢查照常進行，tailnet 只是多一條路。
final class TailnetGateway {
    private let port: UInt16
    private let current = Locked<Session?>(nil)

    init(port: UInt16) { self.port = port }

    deinit { stop() }

    func start(on node: TailnetNode) throws {
        stop()
        let session = Session(listener: try node.listen(port: port))
        current.withLock { $0 = session }
        let port = self.port
        let thread = Thread { session.acceptLoop(forwardingTo: port) }
        thread.name = "ipadremote.tailnet.accept"
        thread.start()
    }

    func stop() {
        current.withLock { session in
            session?.stop()
            session = nil
        }
    }

    /// 一次監聽：各自的停止旗標，停用後重新啟用不會互相干擾
    private final class Session {
        private let listener: tailscale_listener
        private let stopped = Locked(false)

        init(listener: tailscale_listener) { self.listener = listener }

        func stop() { stopped.withLock { $0 = true } }

        private var isStopped: Bool { stopped.withLock { $0 } }

        func acceptLoop(forwardingTo port: UInt16) {
            // 監聽 fd 只由這條執行緒關閉，避免 fd 號碼被重複使用時誤讀到別人的 fd
            defer { close(listener) }
            while !isStopped {
                // 每秒醒來一次檢查是否已停止
                var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, 1000)
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue } else { return } }
                if p.revents & Int16(POLLIN) == 0 { return }       // 監聽已關閉或出錯
                guard !isStopped, let conn = TailnetNode.accept(listener) else { continue }
                guard let local = LoopbackSocket.connect(port: port) else {
                    close(conn)
                    continue
                }
                TCPBridge.pump(conn, local)
            }
        }
    }
}
