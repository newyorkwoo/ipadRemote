// 用 Mac 的 H264Encoder 產生真實 H.264 封包，給 iPad 端解碼測試使用（模擬器無法編碼）
// 執行：Tools/run-simulation-tests.sh 會自動產生
import Foundation
import CoreMedia
import CoreVideo

func makeStream(width: Int, height: Int, frames: Int) -> Data {
    let encoder = H264Encoder(width: width, height: height, fps: 30, bitRate: 2_000_000)!
    var packets: [Data] = []
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    encoder.onPacket = { packet in
        lock.lock(); packets.append(packet.serialized()); let n = packets.count; lock.unlock()
        if n == frames { done.signal() }
    }
    for i in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * bpr + x * 4
            p[0] = UInt8((x + i * 8) & 255); p[1] = UInt8(y & 255); p[2] = UInt8((i * 20) & 255); p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        encoder.encode(buffer!, presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    _ = done.wait(timeout: .now() + 10)
    var out = Data()
    for p in packets {
        var len = UInt32(p.count).bigEndian
        out.append(Data(bytes: &len, count: 4)); out.append(p)
    }
    return out
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try makeStream(width: 640, height: 400, frames: 10).write(to: dir.appendingPathComponent("h264_640x400.bin"))
try makeStream(width: 1280, height: 720, frames: 3).write(to: dir.appendingPathComponent("h264_1280x720.bin"))
print("fixtures written to", dir.path)
