import Foundation
import Network
import AppKit

/// 監聽 iPad 連線（Bonjour + 固定埠，可在路由器做 Port Forwarding）
final class RemoteServer {
    var onStatus: ((String, Bool) -> Void)?        // (訊息, 是否正常)
    var onClientChanged: ((String?) -> Void)?
    var hostInfoProvider: (() -> HostInfo)?
    /// 測試時關閉螢幕擷取（避免觸發系統權限視窗）
    var streamingEnabled = true

    private let queue = DispatchQueue(label: "ipadremote.server", qos: .userInteractive)
    private var listener: NWListener?
    private var session: ClientSession?            // 目前控制中的連線（已完成 hello）
    private var pendingSessions: [ClientSession] = []
    private let power = PowerManager()
    private var config: (code: String, port: UInt16, name: String, hostID: String)?
    private var restartWork: DispatchWorkItem?

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

    /// 更換配對碼：中斷現有連線並以新金鑰重新監聽
    func disconnectClient() {
        queue.async {
            self.session?.cancel()
            self.pendingSessions.forEach { $0.cancel() }
        }
    }

    private func startListener() {
        restartWork?.cancel()
        listener?.cancel()
        listener = nil
        guard let config else { return }

        let params = SecureTransport.parameters(pairingCode: config.code)
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
        let session = ClientSession(connection: connection, queue: queue, power: power,
                                    hostInfoProvider: { [weak self] in self?.hostInfoProvider?() })
        session.streamingEnabled = streamingEnabled
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

    private let connection: NWConnection
    private let channel: MessageChannel
    private let queue: DispatchQueue
    private let power: PowerManager
    private let hostInfoProvider: () -> HostInfo?
    private let injector = InputInjector()
    private let streamer = ScreenStreamer()
    private let decoder = JSONDecoder()

    var streamingEnabled = true
    private var quality: StreamQuality = .balanced
    private var displayID: CGDirectDisplayID?
    private var ended = false
    private var streamGeneration = 0
    private var inputSourceObserver: NSObjectProtocol?

    /// 流量控制：已送出但 iPad 尚未確認收到的幀數。超過上限就略過新幀（保持畫面即時，而不是排隊變慢）
    static let maxFramesInFlight = 4
    private let flowLock = NSLock()
    private var framesInFlight = 0
    private var flowControl = false

    init(connection: NWConnection, queue: DispatchQueue, power: PowerManager,
         hostInfoProvider: @escaping () -> HostInfo?) {
        self.connection = connection
        self.channel = MessageChannel(connection: connection)
        self.queue = queue
        self.power = power
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
        let streamer = self.streamer
        Task { await streamer.stop() }
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        onEnd?(self)
    }

    // MARK: 訊息處理

    private func handle(_ message: ClientMessage) {
        switch message {
        case let .hello(clientName, version, quality, displayID):
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
            if usePaste {
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
            restartStream()
        case let .setQuality(quality):
            self.quality = quality
            restartStream()
        case .requestKeyframe:
            streamer.requestKeyframe()
        case let .videoAck(count):
            flowLock.withLock { framesInFlight = max(0, framesInFlight - count) }
            streamer.sendSkippedFrameIfNeeded()
        case let .setAudio(enabled):
            streamer.audioEnabled = enabled
        case .wakeDisplay:
            power.wakeDisplay()
        case .goodbye:
            cancel()
        }
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
