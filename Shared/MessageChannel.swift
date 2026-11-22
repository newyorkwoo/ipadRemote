import Foundation
import Network

/// 在 NWConnection 上收送「控制訊息 (JSON)」、「影像封包」與「聲音封包」
final class MessageChannel {
    let connection: NWConnection
    var onControl: ((Data) -> Void)?
    var onVideo: ((Data) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onReceiveError: ((NWError?) -> Void)?

    private let encoder = JSONEncoder()
    private let lock = NSLock()
    private var _pendingVideoSends = 0

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// 尚未送出的影像封包數，用來做壅塞控制（網路慢時丟幀，避免延遲越積越高）
    var pendingVideoSends: Int {
        lock.lock(); defer { lock.unlock() }
        return _pendingVideoSends
    }

    func startReceiving() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let content,
               let message = context?.protocolMetadata(definition: RemoteFramer.definition) as? NWProtocolFramer.Message {
                switch message.frameType {
                case .control: self.onControl?(content)
                case .video: self.onVideo?(content)
                case .audio: self.onAudio?(content)
                }
            }
            if let error {
                self.onReceiveError?(error)
            } else if context?.isFinal == true && content == nil {
                self.onReceiveError?(nil)
            } else {
                self.startReceiving()
            }
        }
    }

    func send<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        send(data, type: .control, completion: nil)
    }

    /// sent：資料已交給網路層後呼叫
    func sendVideo(_ data: Data, sent: (() -> Void)? = nil) {
        lock.lock(); _pendingVideoSends += 1; lock.unlock()
        send(data, type: .video) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self._pendingVideoSends -= 1; self.lock.unlock()
            sent?()
        }
    }

    /// 聲音封包很小（約 16 KB/s），不做丟棄；延遲由 iPad 端的播放緩衝控制
    func sendAudio(_ data: Data) {
        send(data, type: .audio, completion: nil)
    }

    private func send(_ data: Data, type: FrameType, completion: (() -> Void)?) {
        let message = NWProtocolFramer.Message(frameType: type)
        let context = NWConnection.ContentContext(identifier: "\(type)",
                                                  metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in completion?() })
    }
}
