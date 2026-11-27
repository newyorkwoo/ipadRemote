import Foundation
import Network

/// 每個訊息前加 8 bytes 標頭：[類型 UInt32][長度 UInt32]（Big Endian）
enum FrameType: UInt32 {
    case control = 1   // JSON 控制訊息
    case video = 2     // H.264 影像封包
    case audio = 3     // AAC 聲音封包
}

final class RemoteFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: RemoteFramer.self)
    static var label: String { "iPadRemote" }

    private static let headerSize = 8
    /// 每種訊息的長度上限（防止已連線但惡意或故障的對端用超大封包耗盡記憶體）
    /// 控制訊息最大約 200,000 字的文字（含 JSON 跳脫）；影像最大 8 MB；聲音封包很小
    private static func maxPayload(for type: FrameType) -> UInt32 {
        switch type {
        case .control: return 4 * 1024 * 1024
        case .video: return 8 * 1024 * 1024
        case .audio: return 1 * 1024 * 1024
        }
    }

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance,
                      message: NWProtocolFramer.Message,
                      messageLength: Int,
                      isComplete: Bool) {
        var header = Data(count: Self.headerSize)
        header.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: message.frameType.rawValue.bigEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(messageLength).bigEndian, toByteOffset: 4, as: UInt32.self)
        }
        framer.writeOutput(data: header)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var type: UInt32 = 0
            var length: UInt32 = 0
            let parsed = framer.parseInput(minimumIncompleteLength: Self.headerSize,
                                           maximumLength: Self.headerSize) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerSize else { return 0 }
                type = buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
                length = buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
                return Self.headerSize
            }
            guard parsed else { return Self.headerSize }

            guard let frameType = FrameType(rawValue: type), length <= Self.maxPayload(for: frameType) else {
                framer.markFailed(error: .posix(.EBADMSG))
                return 0
            }
            let message = NWProtocolFramer.Message(frameType: frameType)
            if !framer.deliverInputNoCopy(length: Int(length), message: message, isComplete: true) {
                return 0
            }
        }
    }
}

extension NWProtocolFramer.Message {
    convenience init(frameType: FrameType) {
        self.init(definition: RemoteFramer.definition)
        self["type"] = frameType.rawValue
    }

    var frameType: FrameType {
        (self["type"] as? UInt32).flatMap(FrameType.init(rawValue:)) ?? .control
    }
}
