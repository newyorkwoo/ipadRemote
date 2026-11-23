import Foundation
import Network
import AppKit

/// 監聽 iPad 連線（Bonjour + 固定埠）。
/// 跨網路請用 Tailscale；不建議在路由器做 Port Forwarding，那會把這個埠直接暴露在網際網路上。
final class RemoteServer {
    var onStatus: ((String, Bool) -> Void)?        // (訊息, 是否正常)
    var onClientChanged: ((String?) -> Void)?
    /// 有新的 iPad 完成配對（主執行緒）
    var onPaired: ((PairedDevice) -> Void)?
    /// 配對成功後配對碼自動更換（一次性配對碼），新碼於主執行緒回報
    var onPairingCodeChanged: ((String) -> Void)?
    var hostInfoProvider: (() -> HostInfo)?
    let devices: PairedDeviceStore
    /// 測試時關閉螢幕擷取（避免觸發系統權限視窗）
    var streamingEnabled = true
    /// 測試用：替換每條連線的輸入注入器（收集事件，不真的動到滑鼠鍵盤）
    var configureInjector: ((InputInjector) -> Void)?

    private let queue = DispatchQueue(label: "ipadremote.server", qos: .userInteractive)
    private var listener: NWListener?
    private var session: ClientSession?            // 目前控制中的連線（已完成 hello）
    private var pendingSessions: [ClientSession] = []
    private let power = PowerManager()
    private var config: (code: String, port: UInt16, name: String, hostID: String)?
    private var restartWork: DispatchWorkItem?
    private var stoppingListener: NWListener?
    private var startAfterStop = false

    init(devices: PairedDeviceStore = PairedDeviceStore(keychainAccount: nil)) {
        self.devices = devices
    }

    func start(pairingCode: String, port: UInt16, serviceName: String, hostID: String) {
        queue.async {
            self.config = (pairingCode, port, serviceName, hostID)
            self.startListener()
        }
    }

    /// 睡眠喚醒或網路改變後呼叫，確保監聽仍然有效
    func restart() {
        queue.async { self.startListener() }
    }

    /// 中斷目前所有連線（已配對的 iPad 之後仍可重新連入）
    func disconnectClient() {
        queue.async {
            self.session?.cancel()
            self.pendingSessions.forEach { $0.cancel() }
        }
    }

    /// 更換配對碼：只影響尚未配對的新 iPad，已配對的 iPad 用自己的金鑰，不受影響
    func updatePairingCode(_ code: String) {
        queue.async {
            self.config?.code = code
            self.startListener()
        }
    }

    /// 移除一台 iPad：刪除金鑰、中斷它的連線，之後它無法再完成加密交握
    func removeDevice(id: String) {
        queue.async {
            self.devices.remove(id: id)
            if self.session?.deviceID == id { self.session?.cancel() }
            self.pendingSessions.filter { $0.deviceID == id }.forEach { $0.cancel() }
            self.startListener()
        }
    }

    private func startListener() {
        restartWork?.cancel()
        // 先等舊的監聽完全關閉、釋放連接埠，再用新的金鑰重新監聽（否則會 bind 失敗、要等 3 秒重試）。
        // 已建立的連線不受影響。
        if stoppingListener != nil {
            startAfterStop = true
            return
        }
        if let old = listener {
            listener = nil
            stoppingListener = old
            startAfterStop = true
            old.newConnectionHandler = { $0.cancel() }
            old.stateUpdateHandler = { [weak self, weak old] state in
                guard let self else { return }
                switch state {
                case .cancelled, .failed:
                    guard self.stoppingListener === old else { return }
                    self.stoppingListener = nil
                    if self.startAfterStop {
                        self.startAfterStop = false
                        self.startListener()
                    }
                default:
                    break
                }
            }
            old.cancel()
            return
        }
        guard let config else { return }

        // 配對碼（新配對用）+ 每台已配對 iPad 的專屬金鑰；重新監聽不會中斷已建立的連線
        let credentials = [PSKCredential.pairing(config.code)] + devices.all.map(\.credential)
        let params = SecureTransport.parameters(credentials: credentials)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: config.port),
              let listener = try? NWListener(using: params, on: port) else {
            report("無法開啟埠 \(config.port)，稍後重試", ok: false)
            scheduleRestart()
            return
        }
        listener.service = NWListener.Service(name: config.name,
                                              type: RemoteConstants.bonjourType,
                                              domain: nil,
                                              txtRecord: NWTXTRecord(["id": config.hostID, "v": "\(RemoteConstants.protocolVersion)"]))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.report("等待 iPad 連線・埠 \(config.port)", ok: true)
            case .failed(let error):
                self.report("監聽失敗：\(error.localizedDescription)", ok: false)
                self.scheduleRestart()
            case .waiting(let error):
                self.report("等待網路：\(error.localizedDescription)", ok: false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func scheduleRestart() {
        let work = DispatchWorkItem { [weak self] in self?.startListener() }
        restartWork = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        let session = ClientSession(connection: connection, queue: queue, power: power, devices: devices,
                                    hostInfoProvider: { [weak self] in self?.hostInfoProvider?() })
        session.streamingEnabled = streamingEnabled
        session.displayScalingEnabled = streamingEnabled
        configureInjector?(session.injector)
        session.onEnd = { [weak self] ended in
            guard let self else { return }
            self.pendingSessions.removeAll { $0 === ended }
            guard self.session === ended else { return }
            self.session = nil
            DispatchQueue.main.async { self.onClientChanged?(nil) }
        }
        // iPad 可能同時從多個位址（區網、Tailscale…）連進來，只有完成 hello 的那條才成為控制連線，
        // 並取代舊連線（例如斷線重連）。同一時間只允許一台 iPad 控制。
        session.onHello = { [weak self, weak session] name in
            guard let self, let session else { return }
            self.pendingSessions.removeAll { $0 === session }
            let old = self.session
            self.session = session
            if let old, old !== session { old.cancel() }
            DispatchQueue.main.async { self.onClientChanged?(name) }
        }
        session.onPaired = { [weak self] device in
            guard let self else { return }
            // 配對碼只能用一次：配對成功立刻換新碼，並把新 iPad 的金鑰加入監聽
            let newCode = PairingCode.generate()
            self.config?.code = newCode
            self.startListener()
            DispatchQueue.main.async {
                self.onPairingCodeChanged?(newCode)
                self.onPaired?(device)
            }
        }
        pendingSessions.append(session)
        session.start()
    }

    private func report(_ message: String, ok: Bool) {
        DispatchQueue.main.async { self.onStatus?(message, ok) }
    }
}

/// 一條 iPad 連線
final class ClientSession {
    var onEnd: ((ClientSession) -> Void)?
    var onHello: ((String) -> Void)?
    var onPaired: ((PairedDevice) -> Void)?
    /// 已驗證的 iPad（identify 證明通過，或剛完成新配對）
    private(set) var deviceID: String?

    /// 單次文字上限：太長的資料不處理，避免長時間佔住佇列
    static let maxTextLength = 200_000
    /// 超過這個長度改用貼上（逐字輸入每 16 字元要 2ms）
    static let maxTypedLength = 2_000

    private let connection: NWConnection
    private let channel: MessageChannel
    private let queue: DispatchQueue
    private let power: PowerManager
    private let devices: PairedDeviceStore
    private let hostInfoProvider: () -> HostInfo?
    private var helloReceived = false
    let injector = InputInjector()
    private let streamer = ScreenStreamer()
    private let decoder = JSONDecoder()

    var streamingEnabled = true
    private var quality: StreamQuality = .balanced
    private var displayID: CGDirectDisplayID?
    /// iPad 要求的介面大小，以及目前被調整解析度的螢幕（斷線時還原）
    private var interfaceScale: InterfaceScale = .native
    private var scaledDisplay: CGDirectDisplayID?
    /// 測試時不要真的改螢幕解析度
    var displayScalingEnabled = true
    private var ended = false
    private var streamGeneration = 0
    private var inputSourceObserver: NSObjectProtocol?

    /// 流量控制：已送出但 iPad 尚未確認收到的幀數。超過上限就略過新幀（保持畫面即時，而不是排隊變慢）
    static let maxFramesInFlight = 4
    private let flowLock = NSLock()
    private var framesInFlight = 0
    private var flowControl = false

    init(connection: NWConnection, queue: DispatchQueue, power: PowerManager, devices: PairedDeviceStore,
         hostInfoProvider: @escaping () -> HostInfo?) {
        self.connection = connection
        self.channel = MessageChannel(connection: connection)
        self.queue = queue
        self.power = power
        self.devices = devices
        self.hostInfoProvider = hostInfoProvider
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.channel.startReceiving()
            case .failed, .cancelled:
                self.end()
            default:
                break
            }
        }
        channel.onControl = { [weak self] data in
            guard let self, let message = try? self.decoder.decode(ClientMessage.self, from: data) else { return }
            self.handle(message)
        }
        channel.onReceiveError = { [weak self] _ in self?.cancel() }

        streamer.onPacket = { [weak self] data in
            guard let self else { return }
            self.flowLock.withLock { self.framesInFlight += 1 }
            self.channel.sendVideo(data) { [weak self] in self?.streamer.sendSkippedFrameIfNeeded() }
        }
        streamer.canSend = { [weak self] in
            guard let self else { return false }
            guard self.channel.pendingVideoSends < 2 else { return false }
            return self.flowLock.withLock { !self.flowControl || self.framesInFlight < Self.maxFramesInFlight }
        }
        streamer.onAudio = { [weak self] data in self?.channel.sendAudio(data) }
        streamer.onStopped = { [weak self] _ in
            // 例如螢幕關閉或解析度改變 → 1 秒後重新開始擷取
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.restartStream() }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        end()
    }

    private func end() {
        guard !ended else { return }
        ended = true
        injector.releaseAll()
        power.preventIdleSleep(false)
        if let display = scaledDisplay {
            scaledDisplay = nil
            DisplayScaler.shared.release(display, owner: self)
        }
        let streamer = self.streamer
        Task { await streamer.stop() }
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        onEnd?(self)
    }

    // MARK: 訊息處理

    private func handle(_ message: ClientMessage) {
        // 完成 hello（確認身分）之前，不接受任何滑鼠、鍵盤或串流指令
        if !helloReceived {
            switch message {
            case .identify, .hello, .ping, .goodbye: break
            default: return
            }
        }
        switch message {
        case let .identify(id, proof):
            guard !helloReceived, deviceID == nil,
                  let key = devices.key(for: id),
                  let expected = SecureTransport.deviceProof(key: key, connection: connection),
                  SecureTransport.constantTimeEqual(expected, proof) else { return }
            deviceID = id

        case let .hello(clientName, version, quality, displayID):
            let firstHello = !helloReceived
            helloReceived = true
            if let id = deviceID {
                devices.touch(id: id, name: clientName)
            } else if firstHello {
                // 沒有裝置證明 → 這是用配對碼進行的新配對：發給它專屬金鑰
                let device = devices.add(name: clientName)
                deviceID = device.id
                channel.send(ServerMessage.paired(deviceID: device.id, key: device.key))
                onPaired?(device)
            }
            flowLock.withLock {
                flowControl = version >= 2
                framesInFlight = 0
            }
            self.quality = quality
            self.displayID = displayID
            onHello?(clientName)
            power.preventIdleSleep(true)
            power.wakeDisplay()
            DispatchQueue.main.async { [weak self] in
                guard let self, let info = self.hostInfoProvider() else { return }
                self.channel.send(ServerMessage.hello(info))
                self.channel.send(ServerMessage.permissions(screenRecording: CGPreflightScreenCaptureAccess(),
                                                            accessibility: AXIsProcessTrusted()))
                self.observeInputSources()
            }
            restartStream()

        case let .ping(id):
            channel.send(ServerMessage.pong(id: id))

        case let .mouseMove(x, y):
            injector.moveAbsolute(x: x, y: y)
        case let .mouseMoveRelative(dx, dy):
            injector.moveRelative(dx: dx, dy: dy)
        case let .mouseButton(button, down, clickCount, modifiers):
            injector.button(button, down: down, clickCount: clickCount, modifiers: modifiers)
        case let .click(button, clickCount, modifiers):
            injector.click(button, clickCount: clickCount, modifiers: modifiers)
        case let .scroll(dx, dy):
            injector.scroll(dx: dx, dy: dy)

        case let .key(keyCode, down, modifiers):
            injector.key(keyCode, down: down, modifiers: modifiers)
        case let .keyPress(keyCode, modifiers):
            injector.keyPress(keyCode, modifiers: modifiers)
        case let .text(text, usePaste):
            let length = text.utf16.count
            guard length <= Self.maxTextLength else {
                channel.send(ServerMessage.notice("文字太長（超過 \(Self.maxTextLength) 字元），未送出。"))
                return
            }
            if usePaste || length > Self.maxTypedLength {
                DispatchQueue.main.async { self.injector.paste(text) }
            } else {
                injector.type(text)
            }

        case let .selectInputSource(id):
            DispatchQueue.main.async { InputSourceManager.select(id: id) }
        case .nextInputSource:
            DispatchQueue.main.async { InputSourceManager.selectNext() }

        case let .selectDisplay(id):
            displayID = id
            applyInterfaceScale()
            restartStream()
        case let .setInterfaceScale(scale):
            guard scale != interfaceScale || scale != .native else { return }
            interfaceScale = scale
            applyInterfaceScale(report: true)
            restartStream()
        case let .setQuality(quality):
            self.quality = quality
            restartStream()
        case .requestKeyframe:
            streamer.requestKeyframe()
        case let .videoAck(count):
            flowLock.withLock { framesInFlight -= min(max(count, 0), framesInFlight) }
            streamer.sendSkippedFrameIfNeeded()
        case let .setAudio(enabled):
            streamer.audioEnabled = enabled
        case .wakeDisplay:
            power.wakeDisplay()
        case .goodbye:
            cancel()
        }
    }

    /// 把介面大小套用到目前串流的螢幕；換螢幕時先還原前一個
    private func applyInterfaceScale(report: Bool = false) {
        guard displayScalingEnabled, !ended else { return }
        let target = displayID.flatMap { id in Self.onlineDisplays().contains(id) ? id : nil } ?? CGMainDisplayID()
        if let previous = scaledDisplay, previous != target {
            DisplayScaler.shared.release(previous, owner: self, after: 0)
            scaledDisplay = nil
        }
        guard interfaceScale != .native || scaledDisplay != nil else { return }
        let outcome = DisplayScaler.shared.apply(interfaceScale, to: target, owner: self)
        scaledDisplay = outcome.kind == .applied ? target : nil
        guard report else { return }
        let message: String
        switch outcome.kind {
        case .applied:
            message = "Mac 螢幕暫時調整為 \(outcome.width)×\(outcome.height)，中斷連線後會還原。"
        case .restored:
            message = "Mac 螢幕已還原為原本的解析度。"
        case .alreadyNative:
            message = "這個螢幕的介面已經夠大（\(outcome.width)×\(outcome.height)），不需要調整。"
        case .unavailable:
            message = "這個螢幕沒有適合的較低解析度可以切換。"
        }
        channel.send(ServerMessage.notice(message))
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func observeInputSources() {
        guard inputSourceObserver == nil else { return }
        let send = { [weak self] in
            self?.channel.send(ServerMessage.inputSources(InputSourceManager.list()))
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: InputSourceManager.changedNotification, object: nil, queue: .main) { _ in send() }
    }

    private func restartStream() {
        guard !ended, streamingEnabled else { return }
        streamGeneration += 1
        let generation = streamGeneration
        let quality = self.quality
        let displayID = self.displayID
        Task { [weak self, streamer] in
            do {
                let result = try await streamer.start(displayID: displayID, quality: quality)
                self?.queue.async {
                    guard let self, generation == self.streamGeneration, !self.ended else { return }
                    self.displayID = result.displayID
                    self.injector.displayID = result.displayID
                    self.channel.send(ServerMessage.streamStarted(displayID: result.displayID,
                                                                  pixelWidth: result.pixelWidth,
                                                                  pixelHeight: result.pixelHeight))
                }
            } catch {
                self?.channel.send(ServerMessage.notice(
                    "無法擷取螢幕：\(error.localizedDescription)。請在 Mac「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許 iPad Remote Agent。"))
            }
        }
    }
}
