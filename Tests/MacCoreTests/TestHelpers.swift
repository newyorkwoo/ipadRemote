import XCTest
import Network

/// 在測試中執行一個加密的伺服器（模擬 Mac 端）
final class LoopbackServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.server")
    private(set) var channels: [MessageChannel] = []
    var onControl: ((MessageChannel, Data) -> Void)?
    private var readyPort: UInt16?

    init(code: String) throws {
        listener = try NWListener(using: SecureTransport.parameters(pairingCode: code))
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let channel = MessageChannel(connection: connection)
            self.channels.append(channel)
            channel.onControl = { [weak self, weak channel] data in
                guard let self, let channel else { return }
                self.onControl?(channel, data)
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state { channel.startReceiving() }
            }
            connection.start(queue: self.queue)
        }
    }

    func start() -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port!.rawValue
    }

    func stop() {
        listener.cancel()
        channels.forEach { $0.connection.cancel() }
    }
}

/// 明文 TCP 轉發代理：記錄經過的所有位元組，用來驗證線路上沒有明文
final class SniffingProxy {
    let listener: NWListener
    let queue = DispatchQueue(label: "test.proxy")
    private let lock = NSLock()
    private var captured = Data()
    private var connections: [NWConnection] = []

    var capturedBytes: Data { lock.withLock { captured } }

    init(targetPort: UInt16) throws {
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
            self.connections += [inbound, outbound]
            inbound.start(queue: self.queue)
            outbound.start(queue: self.queue)
            self.pump(from: inbound, to: outbound)
            self.pump(from: outbound, to: inbound)
        }
    }

    func start() -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port!.rawValue
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock { self.captured.append(data) }
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if error == nil && !isComplete { self.pump(from: source, to: destination) }
        }
    }
}

/// 測試用客戶端（模擬 iPad 端）
final class TestClient {
    let connection: NWConnection
    let channel: MessageChannel
    let queue = DispatchQueue(label: "test.client")
    var onControl: ((Data) -> Void)?
    var onVideo: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onState: ((NWConnection.State) -> Void)?

    convenience init(code: String, port: UInt16) {
        self.init(credential: .pairing(code), port: port)
    }

    init(credential: PSKCredential, port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: SecureTransport.parameters(credentials: [credential]))
        channel = MessageChannel(connection: connection)
    }

    func start() {
        channel.onControl = { [weak self] in self?.onControl?($0) }
        channel.onVideo = { [weak self] in self?.onVideo?($0) }
        channel.onAudio = { [weak self] in self?.onAudio?($0) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.channel.startReceiving() }
            self.onState?(state)
        }
        connection.start(queue: queue)
    }

    func cancel() { connection.cancel() }
}

func decodeServer(_ data: Data) -> ServerMessage? { try? JSONDecoder().decode(ServerMessage.self, from: data) }
func decodeClient(_ data: Data) -> ClientMessage? { try? JSONDecoder().decode(ClientMessage.self, from: data) }

extension NWError {
    var isTLS: Bool { if case .tls = self { return true }; return false }
}
