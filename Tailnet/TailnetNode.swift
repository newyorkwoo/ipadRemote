import Foundation
import Combine
import CTailscale
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// tailnet 上的其他節點
struct TailnetPeer: Hashable, Identifiable {
    var id: String { hostName }
    var hostName: String
    var ipv4: String?
    var online: Bool
}

/// libtailscale（tsnet）的薄包裝：一個在 App 行程內執行的使用者模式 Tailscale 節點。
/// 不需要安裝 Tailscale App、不用開 VPN，也不會改動系統的網路設定。
final class TailnetNode {
    private let handle: tailscale
    private var closed = false
    private let lock = NSLock()

    /// controlURL：nil 用官方 Tailscale；也可指定自架的 Headscale 或測試用控制伺服器
    init(hostName: String, dataDir: URL, controlURL: String? = nil) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        handle = tailscale_new()
        tailscale_set_dir(handle, dataDir.path)
        tailscale_set_hostname(handle, hostName)
        if let controlURL, !controlURL.isEmpty { tailscale_set_control_url(handle, controlURL) }
        tailscale_set_logfd(handle, ProcessInfo.processInfo.environment["IPADREMOTE_TAILNET_LOG"] != nil ? 2 : -1)
        // 不等待登入完成：沒有登入過時會進入 NeedsLogin，並在狀態中提供登入網址
        guard tailscale_start(handle) == 0 else {
            let message = Self.errorMessage(handle)
            tailscale_close(handle)
            throw NSError(domain: "Tailnet", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        tailscale_close(handle)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    // MARK: 狀態

    struct Status {
        var backendState: String
        var authURL: URL?
        var selfIPv4: String?
        var account: String?
        var tailnetName: String?
        var peers: [TailnetPeer]
    }

    private struct StatusJSON: Decodable {
        struct Peer: Decodable {
            var HostName: String?
            var TailscaleIPs: [String]?
            var Online: Bool?
            var UserID: Int64?
        }
        struct Tailnet: Decodable { var Name: String? }
        struct User: Decodable { var LoginName: String?; var DisplayName: String? }
        var BackendState: String?
        var AuthURL: String?
        var TailscaleIPs: [String]?
        var `Self`: Peer?
        var Peer: [String: Peer]?
        var CurrentTailnet: Tailnet?
        var User: [String: User]?
    }

    func status() -> Status? {
        guard !isClosed else { return nil }
        var out: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(handle, &out) == 0, let out else { return nil }
        defer { free(out) }
        let data = Data(bytes: out, count: strlen(out))
        guard let json = try? JSONDecoder().decode(StatusJSON.self, from: data) else { return nil }
        let ipv4 = (json.TailscaleIPs ?? json.Self?.TailscaleIPs ?? []).first(where: { $0.contains(".") })
        let account = json.Self?.UserID.flatMap { json.User?[String($0)] }.flatMap { $0.LoginName ?? $0.DisplayName }
        let peers = (json.Peer ?? [:]).values.compactMap { peer -> TailnetPeer? in
            guard let name = peer.HostName else { return nil }
            return TailnetPeer(hostName: name,
                               ipv4: peer.TailscaleIPs?.first(where: { $0.contains(".") }),
                               online: peer.Online ?? false)
        }
        return Status(backendState: json.BackendState ?? "NoState",
                      authURL: json.AuthURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                      selfIPv4: ipv4,
                      account: account,
                      tailnetName: json.CurrentTailnet?.Name,
                      peers: peers.sorted { $0.hostName < $1.hostName })
    }

    // MARK: 連線

    /// 在 tailnet 上監聽 TCP（只在 tailnet 位址上，與系統的同號埠互不衝突）
    func listen(port: UInt16) throws -> tailscale_listener {
        var listener: tailscale_listener = 0
        guard tailscale_listen(handle, "tcp", ":\(port)", &listener) == 0 else {
            throw NSError(domain: "Tailnet", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(handle)])
        }
        return listener
    }

    /// 接受一條連線；listener 關閉或出錯時回傳 nil
    static func accept(_ listener: tailscale_listener) -> tailscale_conn? {
        var conn: tailscale_conn = 0
        return tailscale_accept(listener, &conn) == 0 ? conn : nil
    }

    /// 撥號到 tailnet 上的位址（阻塞，請在背景執行緒呼叫）
    func dial(host: String, port: UInt16) -> tailscale_conn? {
        guard !isClosed else { return nil }
        var conn: tailscale_conn = 0
        return tailscale_dial(handle, "tcp", "\(host):\(port)", &conn) == 0 ? conn : nil
    }

    private static func errorMessage(_ handle: tailscale) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        tailscale_errmsg(handle, &buf, buf.count)
        let message = String(cString: buf)
        return message.isEmpty ? "Tailscale 啟動失敗" : message
    }
}

/// 內嵌 Tailscale 的狀態機：開關、登入、狀態輪詢、登出。Mac 與 iPad 共用。
final class TailnetController: ObservableObject {
    enum Phase: Equatable {
        case off
        case starting
        case needsLogin(URL?)
        case running
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var selfIPv4: String?
    @Published private(set) var account: String?
    @Published private(set) var tailnetName: String?
    @Published private(set) var peers: [TailnetPeer] = []
    @Published private(set) var enabled: Bool

    /// 節點上線（Running）時呼叫一次；Mac 用來開始在 tailnet 上監聽
    var onRunning: ((TailnetNode) -> Void)?
    /// 節點關閉（停用、登出）時呼叫
    var onStopped: (() -> Void)?

    private(set) var node: TailnetNode?
    private let hostName: () -> String
    private let dataDir: URL
    private let queue = DispatchQueue(label: "ipadremote.tailnet")
    private var pollTimer: Timer?
    private var openLoginWhenReady = false
    private var announcedRunning = false
    private static let enabledKey = "tailnet.enabled"

    init(hostName: @escaping () -> String) {
        self.hostName = hostName
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "iPadRemote")
            .appendingPathComponent("tailscale", isDirectory: true)
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var isRunning: Bool { phase == .running }

    /// App 啟動時呼叫：之前啟用過就自動上線（不會跳出登入頁）
    func resume() {
        if enabled { start(openLogin: false) }
    }

    /// 使用者按下「啟用」：上線，需要登入時自動打開登入頁
    func enable() {
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start(openLogin: true)
    }

    /// 停用：關閉節點，保留登入狀態（下次啟用不必重新登入）
    func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stop()
        phase = .off
    }

    /// 登出：關閉節點並刪除這台裝置在 tailnet 上的身分（下次啟用需重新登入）
    func logout() {
        disable()
        let dir = dataDir
        queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    func openLogin() {
        if case .needsLogin(let url?) = phase {
            Self.open(url)
        } else {
            openLoginWhenReady = true
        }
    }

    /// App 回到前景時立即更新狀態（iOS 在背景時會暫停節點的網路活動）
    func refresh() {
        guard enabled else { return }
        if node == nil { start(openLogin: false) } else { poll() }
    }

    private func start(openLogin: Bool) {
        openLoginWhenReady = openLogin
        guard node == nil else { poll(); return }
        phase = .starting
        let name = hostName()
        let dir = dataDir
        // 進階：`defaults write <bundle id> tailnet.controlURL https://headscale.example.com` 改用自架 Headscale
        let control = UserDefaults.standard.string(forKey: "tailnet.controlURL")
        queue.async { [weak self] in
            do {
                let node = try TailnetNode(hostName: name, dataDir: dir, controlURL: control)
                DispatchQueue.main.async {
                    guard let self, self.enabled, self.node == nil else { node.close(); return }
                    self.node = node
                    self.announcedRunning = false
                    self.schedulePoll(after: 0.3)
                }
            } catch {
                DispatchQueue.main.async { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let node {
            self.node = nil
            queue.async { node.close() }
            onStopped?()
        }
        announcedRunning = false
        selfIPv4 = nil
        peers = []
    }

    private func schedulePoll(after delay: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let node else { return }
        queue.async { [weak self] in
            let status = node.status()
            DispatchQueue.main.async {
                guard let self, self.node === node else { return }
                self.apply(status, node: node)
            }
        }
    }

    private func apply(_ status: TailnetNode.Status?, node: TailnetNode) {
        guard let status else {
            schedulePoll(after: 2)
            return
        }
        account = status.account
        tailnetName = status.tailnetName
        selfIPv4 = status.selfIPv4
        peers = status.peers
        switch status.backendState {
        case "Running":
            phase = .running
            openLoginWhenReady = false
            if !announcedRunning {
                announcedRunning = true
                onRunning?(node)
            }
            schedulePoll(after: 10)
        case "NeedsLogin", "NeedsMachineAuth":
            phase = .needsLogin(status.authURL)
            if openLoginWhenReady, let url = status.authURL {
                openLoginWhenReady = false
                Self.open(url)
            }
            schedulePoll(after: 1.5)
        default:
            if phase != .running { phase = .starting }
            schedulePoll(after: 1.5)
        }
    }

    private static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
