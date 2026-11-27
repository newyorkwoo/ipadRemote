import Foundation
import Network
import UIKit
import Combine

/// 連線管理：加密連線、心跳偵測、斷線自動重連、Mac 睡眠時自動送喚醒封包
final class RemoteClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int, reason: String)
        case failed(String)
    }

    struct Permissions: Equatable {
        var screenRecording = true
        var accessibility = true
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var device: SavedMac
    @Published private(set) var hostInfo: HostInfo?
    @Published private(set) var inputSources: [InputSourceInfo] = []
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var latencyMs: Int?
    @Published private(set) var permissions = Permissions()
    @Published private(set) var currentDisplayID: UInt32?
    @Published private(set) var lastWakeSent: Date?
    @Published var notice: String?
    @Published var quality: StreamQuality {
        didSet { if quality != oldValue { send(.setQuality(quality)) } }
    }

    /// Mac 介面大小：串流期間暫時降低 Mac 螢幕的「看起來像」解析度（每台 Mac 各自記住）
    @Published var interfaceScale: InterfaceScale {
        didSet {
            guard interfaceScale != oldValue else { return }
            UserDefaults.standard.set(interfaceScale.rawValue, forKey: Self.interfaceScaleKey(device.id))
            send(.setInterfaceScale(interfaceScale))
        }
    }

    static func interfaceScaleKey(_ id: UUID) -> String { "interfaceScale.\(id.uuidString)" }

    /// Mac 聲音轉送到 iPad（記住使用者的選擇）
    @Published var audioEnabled: Bool = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true {
        didSet {
            guard audioEnabled != oldValue else { return }
            UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
            media.withLock { $0.audioEnabled = audioEnabled }
            send(.setAudio(enabled: audioEnabled))
            if !audioEnabled { audio.reset() }
        }
    }

    let renderer = VideoRenderer()
    let audio = AudioPlayer()
    var onHostInfo: ((HostInfo, StreamQuality) -> Void)?

    private let browser: BonjourBrowser
    /// 內嵌 Tailscale（啟用時，換到任何網路都能連回 Mac）
    private let tailnet: TailnetController?
    private var connection: NWConnection?
    private var racing: [NWConnection] = []
    private var channel: MessageChannel?
    private var generation = 0 {
        didSet { media.withLock { $0.generation = generation } }
    }
    /// 網路收發在獨立的高優先權佇列：影像解碼、顯示不必排在主執行緒的 UI 工作後面
    private let netQueue = DispatchQueue(label: "ipadremote.net", qos: .userInteractive)
    /// netQueue 上讀取的狀態（主執行緒寫入）
    private struct MediaState { var generation = 0; var audioEnabled = true }
    private let media = Locked(MediaState())
    private var attempt = 0
    /// 這一輪連線競賽的狀態
    private var raceSawTLSError = false
    private var raceLastError: NWError?
    private var pendingTailnetDials = 0
    private var tailnetObserver: AnyCancellable?
    private var tlsFailures = 0
    private var userStopped = true
    private var hasConnectedOnce = false
    private var lastReceived = Date()
    private var heartbeat: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    private var pingSentAt: [UInt64: Date] = [:]
    private var nextPingID: UInt64 = 0
    /// 最近的 RTT 樣本（毫秒），顯示中位數以減少單次量測的跳動
    private var rttSamples: [Int] = []
    private var lastKeyframeRequest = Date.distantPast
    private let decoder = JSONDecoder()

    /// 每 0.25 秒送一次 ping：同時是存活偵測，也讓 Wi‑Fi 電台保持醒著（閒置後第一個操作才不會多等）
    private static let heartbeatInterval: TimeInterval = 0.25
    private static let rttWindow = 20
    private static let deadAfter: TimeInterval = 7
    private static let connectTimeout: TimeInterval = 8

    init(device: SavedMac, browser: BonjourBrowser, tailnet: TailnetController? = nil) {
        self.device = device
        self.browser = browser
        self.tailnet = tailnet
        self.quality = device.quality
        self.interfaceScale = UserDefaults.standard.string(forKey: Self.interfaceScaleKey(device.id))
            .flatMap(InterfaceScale.init(rawValue:)) ?? .native
        renderer.onSizeChange = { [weak self] size in DispatchQueue.main.async { self?.videoSize = size } }
        renderer.onNeedKeyframe = { [weak self] in DispatchQueue.main.async { self?.requestKeyframeThrottled() } }
        let audioOn = audioEnabled
        media.withLock { $0.audioEnabled = audioOn }
        // tailnet 上線（例如 App 回到前景）時，正在重試的連線立即再試，不必等退避計時
        tailnetObserver = tailnet?.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self, phase == .running, !self.userStopped, self.state != .connected else { return }
            DispatchQueue.main.async {
                self.attempt = 0
                self.openConnection()
            }
        }
    }

    deinit {
        heartbeat?.invalidate()
        pathMonitor?.cancel()
        connection?.cancel()
    }

    // MARK: 公開操作

    func connect() {
        userStopped = false
        attempt = 0
        tlsFailures = 0
        startHeartbeat()
        startPathMonitor()
        openConnection()
    }

    func disconnect() {
        userStopped = true
        reconnectWork?.cancel()
        heartbeat?.invalidate()
        heartbeat = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        channel?.send(ClientMessage.goodbye)
        let old = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { old?.cancel() }
        racing.forEach { $0.cancel() }
        racing = []
        connection = nil
        channel = nil
        generation += 1
        audio.stop()
        state = .idle
    }

    func retryNow() {
        guard !userStopped else { return connect() }
        attempt = 0
        tlsFailures = 0
        openConnection()
    }

    /// App 上鎖時為 true：滑鼠、鍵盤、文字輸入一律不送出
    var inputBlocked = false

    func send(_ message: ClientMessage) {
        guard state == .connected else { return }
        if inputBlocked && message.isUserInput { return }
        channel?.send(message)
    }

    func wakeMac() {
        WakeOnLAN.wake(device) { [weak self] count in
            guard let self else { return }
            if count > 0 {
                self.lastWakeSent = Date()
            } else if self.device.macAddress.isEmpty {
                self.notice = "尚未取得 MAC 位址，無法喚醒。請先在 Mac 醒著時成功連線一次。"
            }
        }
    }

    /// App 回到前景：連線可能早已被系統關閉，立即檢查並重連
    func appDidBecomeActive() {
        guard !userStopped else { return }
        if state != .connected || Date().timeIntervalSince(lastReceived) > 3 {
            attempt = 0
            openConnection()
        } else {
            requestKeyframeThrottled()
        }
    }

    // MARK: 連線流程

    /// 所有可能連到 Mac 的路徑：Bonjour（同網路）、手動外部位址、Tailscale、Mac 回報的區網位址
    func candidateEndpoints() -> [NWEndpoint] {
        var list: [NWEndpoint] = []
        var seen = Set<String>()
        if let bonjour = browser.endpoint(for: device) { list.append(bonjour) }
        guard let port = NWEndpoint.Port(rawValue: device.port) else { return list }
        func add(_ host: String?) {
            guard let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  seen.insert(host).inserted else { return }
            list.append(.hostPort(host: NWEndpoint.Host(host), port: port))
        }
        add(device.host)
        let known = (device.knownAddresses ?? []) + [device.lastIPv4].compactMap { $0 }
        known.filter(NetworkAddress.isTailscale).forEach(add)
        known.filter { !NetworkAddress.isTailscale($0) }.forEach(add)
        return list
    }

    /// 透過內嵌 Tailscale 可以撥的位址：Mac 回報過的 Tailscale 位址 + tailnet 上屬於這台 Mac 的節點
    func tailnetTargets() -> [String] {
        guard let tailnet, tailnet.isRunning else { return [] }
        var list: [String] = []
        for peer in tailnet.peers {
            guard let ip = peer.ipv4, let parsed = TailnetNaming.parseMac(peer.hostName),
                  TailnetNaming.matches(hostID: device.hostID, idTag: parsed.idTag) else { continue }
            list.append(ip)
        }
        let known = (device.knownAddresses ?? []) + [device.host]
        list += known.map { $0.trimmingCharacters(in: .whitespaces) }.filter(NetworkAddress.isTailscale)
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private func cancelConnections() {
        connection?.cancel()
        racing.forEach { $0.cancel() }
        connection = nil
        channel = nil
        racing = []
    }

    /// 同時向所有候選位址發起加密連線，最先完成的勝出，其餘取消
    private func openConnection() {
        reconnectWork?.cancel()
        cancelConnections()
        generation += 1
        let gen = generation

        // 已配對 → 用專屬裝置金鑰；尚未配對 → 用一次性配對碼
        let credential = device.credential
        let psk: PSKCredential
        if let credential {
            psk = .device(id: credential.deviceID, key: credential.key)
        } else if PairingCode.isValid(device.pairingCode) {
            psk = .pairing(device.pairingCode)
        } else {
            state = .failed("這台 Mac 尚未配對，請編輯這台 Mac 並輸入 Mac 選單列上的配對碼。")
            return
        }

        let endpoints = candidateEndpoints()
        let tailnetHosts = tailnetTargets()
        guard !endpoints.isEmpty || !tailnetHosts.isEmpty else {
            connectionLost(gen, reason: device.hasRemoteRoute ? "找不到這台 Mac" : Self.noRouteHint)
            return
        }

        if !hasConnectedOnce && attempt == 0 {
            state = .connecting
        }

        raceSawTLSError = false
        raceLastError = nil
        pendingTailnetDials = 0
        for endpoint in endpoints {
            startCandidate(endpoint, psk: psk, paired: credential != nil, gen: gen)
        }
        // 內嵌 Tailscale：先在 tailnet 上撥號，成功後才加入競賽
        if let node = tailnet?.node {
            for host in tailnetHosts {
                pendingTailnetDials += 1
                TailnetDialer.endpoint(via: node, host: host, port: device.port) { [weak self] endpoint in
                    guard let self, gen == self.generation else { return }
                    self.pendingTailnetDials -= 1
                    if let endpoint, self.connection == nil {
                        self.startCandidate(endpoint, psk: psk, paired: credential != nil, gen: gen)
                    } else {
                        self.raceCandidateFinished(gen, paired: credential != nil)
                    }
                }
            }
        }

        // 連線逾時保護（例如 Mac 睡眠中 SYN 沒有回應）
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, gen == self.generation, self.state != .connected else { return }
            self.connectionLost(gen, reason: "連線逾時，Mac 可能正在休眠或不在同一個網路")
        }
    }

    private func startCandidate(_ endpoint: NWEndpoint, psk: PSKCredential, paired: Bool, gen: Int) {
        let candidate = NWConnection(to: endpoint, using: SecureTransport.parameters(credentials: [psk]))
        racing.append(candidate)
        candidate.stateUpdateHandler = { [weak self, weak candidate] newState in
          DispatchQueue.main.async {
            guard let self, let candidate, gen == self.generation else { return }
            switch newState {
            case .ready:
                if self.connection == nil {
                    self.adopt(candidate, gen: gen)
                } else if self.connection !== candidate {
                    candidate.cancel()
                }
            case .waiting(let error), .failed(let error):
                if self.connection === candidate {
                    // 已建立的連線之後才斷掉
                    self.connectionLost(gen, reason: Self.describe(error))
                    return
                }
                guard self.racing.contains(where: { $0 === candidate }) else { return }
                self.racing.removeAll { $0 === candidate }
                candidate.cancel()
                if case .tls = error { self.raceSawTLSError = true }
                self.raceLastError = error
                self.raceCandidateFinished(gen, paired: paired)
            default:
                break
            }
          }
        }
        candidate.start(queue: netQueue)
    }

    /// 一條路徑失敗後呼叫：所有路徑（含仍在撥號的 tailnet）都失敗才算這一輪失敗
    private func raceCandidateFinished(_ gen: Int, paired: Bool) {
        guard gen == generation, racing.isEmpty, pendingTailnetDials == 0, connection == nil else { return }
        if raceSawTLSError {
            tlsFailures += 1
            if tlsFailures >= 3 {
                fail(!paired
                     ? "加密交握失敗：配對碼不正確或已失效（配對碼只能使用一次）。請在 Mac 選單列取得目前的配對碼。"
                     : "加密交握失敗：這台 iPad 的配對可能已在 Mac 上被移除。請在 Mac 選單列取得新的配對碼，編輯這台 Mac 重新配對。")
                return
            }
        }
        let reason = raceLastError.map(Self.describe) ?? "無法連線"
        connectionLost(gen, reason: device.hasRemoteRoute || attempt < 2
                       ? reason : "\(reason)\n\(Self.noRouteHint)")
    }

    private func adopt(_ connection: NWConnection, gen: Int) {
        racing.removeAll { $0 === connection }
        racing.forEach { $0.cancel() }
        racing = []

        let channel = MessageChannel(connection: connection)
        channel.onControl = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.lastReceived = Date()
                self.handle(data)
            }
        }
        // 影像與聲音直接在 netQueue 處理（不經主執行緒），收到就回報讓 Mac 繼續送
        channel.onVideo = { [weak self, weak channel] data in
            guard let self, self.media.withLock({ $0.generation }) == gen else { return }
            channel?.send(ClientMessage.videoAck(count: 1))
            self.renderer.handle(data)
        }
        channel.onAudio = { [weak self] data in
            guard let self else { return }
            let state = self.media.withLock { $0 }
            guard state.generation == gen, state.audioEnabled else { return }
            self.audio.handle(data)
        }
        channel.onReceiveError = { [weak self] _ in
            DispatchQueue.main.async { self?.connectionLost(gen, reason: "連線中斷") }
        }
        self.connection = connection
        self.channel = channel

        lastReceived = Date()
        channel.startReceiving()
        renderer.prepareForNewStream()
        // 已配對：先證明自己是哪一台（綁定這條連線，無法重送）；沒送的話 Mac 會當成新配對
        if let credential = device.credential,
           let proof = SecureTransport.deviceProof(key: credential.key, connection: connection) {
            channel.send(ClientMessage.identify(deviceID: credential.deviceID, proof: proof))
        }
        channel.send(ClientMessage.hello(clientName: UIDevice.current.name,
                                         protocolVersion: RemoteConstants.protocolVersion,
                                         quality: quality,
                                         displayID: currentDisplayID))
        channel.send(ClientMessage.setAudio(enabled: audioEnabled))
        if interfaceScale != .native {
            channel.send(ClientMessage.setInterfaceScale(interfaceScale))
        }
        audio.reset()
    }

    static let noRouteHint = "iPad 與 Mac 不在同一個網路時，請在 Mac 選單列與這台 iPad 的「跨網路連線」登入同一個帳號。"

    private func connectionLost(_ gen: Int, reason: String) {
        guard gen == generation, !userStopped else { return }
        if case .failed = state { return }

        cancelConnections()
        audio.reset()
        generation += 1
        attempt += 1

        // 連不上時自動喚醒：第 2 次失敗及之後每 6 次送一次魔術封包
        if !device.macAddress.isEmpty && (attempt == 2 || attempt % 6 == 0) {
            wakeMac()
        }

        state = .reconnecting(attempt: attempt, reason: reason)
        // 指數退避：0.5s → 0.8s → 1.3s … 最多 5 秒，永不放棄直到使用者結束
        let delay = min(0.5 * pow(1.6, Double(attempt - 1)), 5)
        let work = DispatchWorkItem { [weak self] in self?.openConnection() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fail(_ message: String) {
        reconnectWork?.cancel()
        cancelConnections()
        generation += 1
        state = .failed(message)
    }

    // MARK: 訊息處理

    private func handle(_ data: Data) {
        guard let message = try? decoder.decode(ServerMessage.self, from: data) else { return }
        switch message {
        case .hello(let info):
            hostInfo = info
            inputSources = info.inputSources
            device.apply(info)
            onHostInfo?(info, quality)
            attempt = 0
            tlsFailures = 0
            hasConnectedOnce = true
            state = .connected
        case .pong(let id):
            if let sent = pingSentAt.removeValue(forKey: id) {
                rttSamples.append(Int(Date().timeIntervalSince(sent) * 1000))
                if rttSamples.count > Self.rttWindow { rttSamples.removeFirst(rttSamples.count - Self.rttWindow) }
                let sorted = rttSamples.sorted()
                latencyMs = sorted[sorted.count / 2]
            }
        case .inputSources(let list):
            inputSources = list
        case let .streamStarted(displayID, _, _):
            currentDisplayID = displayID
        case let .permissions(screen, accessibility):
            permissions = Permissions(screenRecording: screen, accessibility: accessibility)
        case .notice(let text):
            notice = text
        case let .paired(deviceID, key):
            SavedMac.storePairing(DeviceCredential(deviceID: deviceID, key: key), for: device.id)
        }
    }

    private func requestKeyframeThrottled() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        send(.requestKeyframe)
    }

    // MARK: 心跳與網路監控

    private func startHeartbeat() {
        heartbeat?.invalidate()
        rttSamples.removeAll()
        latencyMs = nil
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !userStopped, state == .connected else { return }
        if Date().timeIntervalSince(lastReceived) > Self.deadAfter {
            connectionLost(generation, reason: "網路沒有回應")
            return
        }
        nextPingID += 1
        pingSentAt[nextPingID] = Date()
        pingSentAt = pingSentAt.filter { Date().timeIntervalSince($0.value) < 10 }
        channel?.send(ClientMessage.ping(id: nextPingID))
    }

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, !self.userStopped else { return }
            let satisfied = path.status == .satisfied
            defer { self.lastPathSatisfied = satisfied }
            // 網路恢復（例如切換 Wi‑Fi、從行動網路回到家）→ 立即重連，不必等退避計時
            if satisfied && !self.lastPathSatisfied && self.state != .connected {
                self.attempt = 0
                self.openConnection()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "Mac 拒絕連線，請確認 iPad Remote Agent 正在執行"
        case .posix(let code) where code == .ENETUNREACH || code == .EHOSTUNREACH:
            return "無法連到 Mac 所在的網路"
        case .posix(let code) where code == .ETIMEDOUT:
            return "連線逾時，Mac 可能正在休眠"
        case .dns:
            return "找不到主機位址"
        case .tls:
            return "加密交握失敗"
        default:
            return error.localizedDescription
        }
    }
}

extension ClientMessage {
    /// 會操作到 Mac 的訊息（App 上鎖時要擋下）
    var isUserInput: Bool {
        switch self {
        case .mouseMove, .mouseMoveRelative, .mouseButton, .click, .scroll,
             .key, .keyPress, .text, .selectInputSource, .nextInputSource:
            return true
        default:
            return false
        }
    }
}
