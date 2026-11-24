import Foundation
import Network
import Darwin

/// 透過內嵌 Tailscale 節點連到 Mac。
///
/// 先在 tailnet 上撥號成功，才開一個只接受一次連線的本機埠交給 NWConnection；
/// TLS-PSK 交握仍由 NWConnection 端對端進行，tailnet 只搬運密文。
/// 先撥號再交出埠，可避免「Mac 不在線」被誤判成 TLS 失敗（連續 TLS 失敗會被當成配對碼錯誤而停止重試）。
enum TailnetDialer {
    private static let dialTimeout: TimeInterval = 8
    private static let handoffTimeout: TimeInterval = 10
    /// 同一個目標同時只撥一次：Mac 離線時撥號可能卡很久，不要每次重連都多開一條執行緒
    private static let inFlight = Locked<Set<String>>([])

    /// 在背景撥號；成功時以本機端點回呼（主執行緒），失敗或逾時回呼 nil
    static func endpoint(via node: TailnetNode, host: String, port: UInt16,
                         completion: @escaping (NWEndpoint?) -> Void) {
        let key = "\(host):\(port)"
        guard inFlight.withLock({ $0.insert(key).inserted }) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // 逾時與撥號結果只有先到的那個生效
        let finished = Locked(false)
        func finish(_ endpoint: NWEndpoint?) -> Bool {
            guard finished.withLock({ done in defer { done = true }; return !done }) else { return false }
            DispatchQueue.main.async { completion(endpoint) }
            return true
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + dialTimeout) { _ = finish(nil) }

        Thread.detachNewThread {
            let conn = node.dial(host: host, port: port)
            inFlight.withLock { _ = $0.remove(key) }
            guard let conn else { _ = finish(nil); return }
            guard let listener = OneShotLoopbackListener() else {
                close(conn)
                _ = finish(nil)
                return
            }
            guard finish(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listener.port)!)) else {
                close(conn)          // 已逾時，呼叫端早就放棄了
                return
            }
            guard let local = listener.acceptOnce(timeout: handoffTimeout) else {
                close(conn)
                return
            }
            var one: Int32 = 1
            _ = setsockopt(local, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            TCPBridge.pump(local, conn)
        }
    }
}
