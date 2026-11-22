import XCTest
import AVFoundation

/// 遠端聲音：AAC 編解碼品質、封包格式、透過加密連線傳送
final class AudioCodecTests: XCTestCase {
    /// 產生 seconds 秒的正弦波，以 ScreenCaptureKit 常見的 10 ms 小塊切開
    static func sineChunks(frequency: Double, seconds: Double, amplitude: Float = 0.5) -> [AVAudioPCMBuffer] {
        let chunk: AVAudioFrameCount = 480
        let total = Int(seconds * RemoteAudio.sampleRate)
        return stride(from: 0, to: total, by: Int(chunk)).map { start in
            let buffer = AVAudioPCMBuffer(pcmFormat: RemoteAudio.pcmFormat, frameCapacity: chunk)!
            buffer.frameLength = chunk
            for i in 0..<Int(chunk) {
                let v = Float(sin(2 * .pi * frequency * Double(start + i) / RemoteAudio.sampleRate)) * amplitude
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = -v
            }
            return buffer
        }
    }

    /// 編碼 → 解碼後，音量與音高要正確，兩聲道都要保留
    func testAACRoundTripKeepsPitchLevelAndStereo() throws {
        let encoder = AACEncoder()
        let decoder = try XCTUnwrap(AACDecoder())
        var packets: [Data] = []
        for buffer in Self.sineChunks(frequency: 440, seconds: 2) { packets += encoder.encode(buffer) }

        let bytes = packets.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(packets.count, 80, "2 秒應產生約 93 個 AAC 封包")
        XCTAssertLessThan(Double(bytes * 8) / 2, 200_000, "位元率應遠低於畫面（< 200 kbps）")

        var left: [Float] = [], right: [Float] = []
        for i in stride(from: 0, to: packets.count, by: 3) {
            let out = try XCTUnwrap(decoder.decode(Array(packets[i..<min(i + 3, packets.count)])))
            left += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            right += UnsafeBufferPointer(start: out.floatChannelData![1], count: Int(out.frameLength))
        }
        // 略過 AAC 起始的預熱延遲
        let l = Array(left.dropFirst(4096)), r = Array(right.dropFirst(4096))
        let rms = sqrt(l.reduce(0) { $0 + $1 * $1 } / Float(l.count))
        XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.05, "音量應保持")
        var crossings = 0
        for i in 1..<l.count where (l[i - 1] < 0) != (l[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(l.count) / RemoteAudio.sampleRate)
        XCTAssertEqual(hz, 440, accuracy: 10, "音高應保持 440 Hz")
        let correlation = zip(l, r).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertLessThan(correlation, 0, "左右聲道相位相反的測試訊號應被保留（立體聲）")
    }

    func testAudioPacketFormatAndMalformedInput() {
        let packet = AudioPacket(packets: [Data([1, 2, 3]), Data(repeating: 7, count: 600)])
        XCTAssertEqual(AudioPacket(data: packet.serialized())?.packets, packet.packets)
        XCTAssertNil(AudioPacket(data: Data()))
        XCTAssertNil(AudioPacket(data: Data([0, 0])), "0 個封包")
        XCTAssertNil(AudioPacket(data: Data([0, 1, 0x10, 0x00, 1])), "宣告長度超過實際資料")
        XCTAssertNil(AudioPacket(data: packet.serialized() + Data([9])), "多出的位元組")
        let decoder = AACDecoder()!
        for _ in 0..<500 {
            let noise = Data((0..<Int.random(in: 1...300)).map { _ in UInt8.random(in: 0...255) })
            _ = decoder.decode([noise])   // 雜訊不可當機
        }
    }

    /// 聲音走獨立的封包類型，經 TLS 加密送達，且和控制訊息互不干擾
    func testAudioFramesTravelOverEncryptedChannel() throws {
        let code = PairingCode.generate()
        let server = try LoopbackServer(code: code)
        let encoder = AACEncoder()
        var frames: [Data] = []
        for buffer in Self.sineChunks(frequency: 1000, seconds: 0.5) {
            let packets = encoder.encode(buffer)
            if !packets.isEmpty { frames.append(AudioPacket(packets: packets).serialized()) }
        }
        server.onControl = { channel, data in
            if case .ping = decodeClient(data) {
                frames.forEach { channel.sendAudio($0) }
                channel.send(ServerMessage.pong(id: 1))
            }
        }
        let port = server.start()
        defer { server.stop() }

        var received: [Data] = []
        let done = expectation(description: "audio + pong")
        let client = TestClient(code: code, port: port)
        client.onState = { if case .ready = $0 { client.channel.send(ClientMessage.ping(id: 1)) } }
        client.onAudio = { received.append($0) }
        client.onControl = { if case .pong = decodeServer($0) { done.fulfill() } }
        client.start()
        wait(for: [done], timeout: 10)
        client.cancel()

        XCTAssertEqual(received, frames, "聲音封包必須完整、按順序抵達")
        let decoder = AACDecoder()!
        let decodedFrames = received.compactMap { AudioPacket(data: $0) }
            .compactMap { decoder.decode($0.packets) }.reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertGreaterThan(decodedFrames, 20_000, "iPad 端應能解出約 0.5 秒的聲音")
    }
}
