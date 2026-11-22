import Foundation
import AVFoundation

/// 遠端聲音：Mac 系統聲音 → AAC-LC 48 kHz 立體聲（約 128 kbps）→ iPad 解碼播放
enum RemoteAudio {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2
    static let bitRate = 128_000
    static let framesPerPacket: AVAudioFrameCount = 1024

    /// 播放端使用的 PCM 格式
    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: false)!

    static let aacFormat: AVAudioFormat = {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0,
                                               mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)!
    }()
}

/// 線路格式：[UInt16 封包數]{[UInt16 長度][AAC 封包]}…（Big Endian）
struct AudioPacket {
    var packets: [Data]

    func serialized() -> Data {
        var data = Data()
        func u16(_ v: Int) { data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF)) }
        u16(packets.count)
        for packet in packets {
            u16(packet.count)
            data.append(packet)
        }
        return data
    }

    init(packets: [Data]) { self.packets = packets }

    init?(data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        func u16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        guard let count = u16(), count > 0 else { return nil }
        var packets: [Data] = []
        for _ in 0..<count {
            guard let length = u16(), length > 0, offset + length <= bytes.count else { return nil }
            packets.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        guard offset == bytes.count else { return nil }
        self.packets = packets
    }
}

/// PCM → AAC。輸入格式可為任何 PCM（第一次收到時建立轉換器，格式改變時重建）
final class AACEncoder {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []

    func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
        guard buffer.frameLength > 0 else { return [] }
        if inputFormat != buffer.format || converter == nil {
            guard let converter = AVAudioConverter(from: buffer.format, to: RemoteAudio.aacFormat) else { return [] }
            converter.bitRate = RemoteAudio.bitRate
            self.converter = converter
            inputFormat = buffer.format
            pending.removeAll()
        }
        guard let converter else { return [] }
        pending.append(buffer)

        var packets: [Data] = []
        while true {
            let output = AVAudioCompressedBuffer(format: RemoteAudio.aacFormat, packetCapacity: 8,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            packets.append(contentsOf: Self.packets(in: output))
            if status != .haveData || output.packetCount == 0 { break }
        }
        return packets
    }

    static func packets(in buffer: AVAudioCompressedBuffer) -> [Data] {
        guard let descriptions = buffer.packetDescriptions else { return [] }
        let base = buffer.data.assumingMemoryBound(to: UInt8.self)
        return (0..<Int(buffer.packetCount)).compactMap { i in
            let d = descriptions[i]
            guard d.mDataByteSize > 0 else { return nil }
            return Data(bytes: base + Int(d.mStartOffset), count: Int(d.mDataByteSize))
        }
    }
}

/// AAC → PCM（Float32 非交錯 48 kHz 立體聲）
final class AACDecoder {
    private let converter: AVAudioConverter

    init?() {
        guard let converter = AVAudioConverter(from: RemoteAudio.aacFormat, to: RemoteAudio.pcmFormat) else { return nil }
        self.converter = converter
    }

    func reset() { converter.reset() }

    func decode(_ packets: [Data]) -> AVAudioPCMBuffer? {
        guard !packets.isEmpty, let maxSize = packets.map(\.count).max() else { return nil }
        let input = AVAudioCompressedBuffer(format: RemoteAudio.aacFormat,
                                            packetCapacity: AVAudioPacketCount(packets.count),
                                            maximumPacketSize: maxSize)
        guard let descriptions = input.packetDescriptions else { return nil }
        var offset = 0
        for (i, packet) in packets.enumerated() {
            packet.withUnsafeBytes { raw in
                (input.data + offset).copyMemory(from: raw.baseAddress!, byteCount: packet.count)
            }
            descriptions[i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                           mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)

        guard let output = AVAudioPCMBuffer(pcmFormat: RemoteAudio.pcmFormat,
                                            frameCapacity: RemoteAudio.framesPerPacket * AVAudioFrameCount(packets.count)) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
