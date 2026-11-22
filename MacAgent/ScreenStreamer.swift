import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import AVFoundation

/// 擷取螢幕 → H.264 編碼 → 透過 onPacket 送出；系統聲音 → AAC → onAudio
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPacket: ((Data) -> Void)?
    /// 回傳 false 時表示網路壅塞，略過這一幀（不影響解碼，因為是在編碼前丟）
    var canSend: () -> Bool = { true }
    var onStopped: ((Error?) -> Void)?
    var onAudio: ((Data) -> Void)?
    /// iPad 關閉聲音時不編碼、不傳送
    var audioEnabled: Bool {
        get { lock.withLock { _audioEnabled } }
        set { lock.withLock { _audioEnabled = newValue } }
    }

    private var stream: SCStream?
    private var encoder: H264Encoder?
    private let captureQueue = DispatchQueue(label: "ipadremote.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    private var _audioEnabled = true
    /// 因網路忙碌略過了最新畫面 → 網路空出來時要補送，否則畫面靜止後會停在舊的一幀
    private var skippedLatest = false
    private let audioQueue = DispatchQueue(label: "ipadremote.audio", qos: .userInteractive)
    private var audioEncoder = AACEncoder()

    struct StartResult {
        let displayID: CGDirectDisplayID
        let pixelWidth: Int
        let pixelHeight: Int
    }

    func start(displayID requested: CGDirectDisplayID?, quality: StreamQuality) async throws -> StartResult {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == requested })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "ScreenStreamer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可擷取的螢幕"])
        }

        // 以實際像素尺寸為準，依畫質上限縮放，並確保為偶數
        var pixelWidth = display.width
        var pixelHeight = display.height
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
        }
        if pixelWidth > quality.maxPixelWidth {
            let scale = Double(quality.maxPixelWidth) / Double(pixelWidth)
            pixelWidth = quality.maxPixelWidth
            pixelHeight = Int(Double(pixelHeight) * scale)
        }
        pixelWidth &= ~1
        pixelHeight &= ~1

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 4
        config.capturesAudio = true
        config.sampleRate = Int(RemoteAudio.sampleRate)
        config.channelCount = Int(RemoteAudio.channels)
        config.excludesCurrentProcessAudio = true

        guard let encoder = H264Encoder(width: pixelWidth, height: pixelHeight,
                                        fps: quality.framesPerSecond, bitRate: quality.bitRate) else {
            throw NSError(domain: "ScreenStreamer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立 H.264 編碼器"])
        }
        encoder.onPacket = { [weak self] packet in
            self?.onPacket?(packet.serialized())
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()

        lock.withLock {
            self.stream = stream
            self.encoder = encoder
        }

        return StartResult(displayID: display.displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func stop() async {
        let (stream, encoder) = lock.withLock { () -> (SCStream?, H264Encoder?) in
            defer {
                self.stream = nil
                self.encoder = nil
                self.lastPixelBuffer = nil
                self.skippedLatest = false
            }
            return (self.stream, self.encoder)
        }
        try? await stream?.stopCapture()
        encoder?.invalidate()
    }

    /// 要求關鍵幀。若畫面靜止 ScreenCaptureKit 不會送新幀，所以直接重新編碼最後一幀。
    func requestKeyframe() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let encoder = self.encoder
            let last = self.lastPixelBuffer
            self.lock.unlock()
            encoder?.requestKeyframe()
            if let encoder, let last {
                encoder.encode(last, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        lock.lock()
        lastPixelBuffer = pixelBuffer
        let encoder = self.encoder
        lock.unlock()

        guard canSend() else {
            lock.withLock { skippedLatest = true }
            return
        }
        lock.withLock { skippedLatest = false }
        encoder?.encode(pixelBuffer, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// 網路空出來時呼叫：若剛才略過了最新畫面，立刻補送
    func sendSkippedFrameIfNeeded() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            let (encoder, last, skipped) = self.lock.withLock { (self.encoder, self.lastPixelBuffer, self.skippedLatest) }
            guard skipped, let encoder, let last, self.canSend() else { return }
            self.lock.withLock { self.skippedLatest = false }
            encoder.encode(last, presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    /// 在 audioQueue 上執行：複製 PCM → AAC 編碼 → 送出
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioEnabled, sampleBuffer.isValid,
              var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                          into: pcm.mutableAudioBufferList) == noErr else { return }
        let packets = audioEncoder.encode(pcm)
        if !packets.isEmpty { onAudio?(AudioPacket(packets: packets).serialized()) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
