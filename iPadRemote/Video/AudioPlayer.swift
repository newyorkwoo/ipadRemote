import Foundation
import AVFoundation

/// 播放 Mac 傳來的 AAC 聲音。收到就排入播放（和畫面一樣「即時顯示」，兩者自然對齊），
/// 排隊超過 maxLatency 時丟棄，避免網路卡頓後聲音越來越慢、和畫面脫節。
final class AudioPlayer {
    /// 播放緩衝上限（秒）
    static let maxLatency: Double = 0.25

    private let queue = DispatchQueue(label: "ipadremote.audio-player", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let decoder = AACDecoder()
    private var queuedFrames: AVAudioFrameCount = 0
    private var running = false
    private var configObserver: NSObjectProtocol?

    /// 測試用：解碼後的每個 buffer（未設定時不呼叫）
    var onDecoded: ((AVAudioPCMBuffer) -> Void)?
    /// 是否真的送到喇叭（單元測試時關閉）
    var outputEnabled = true

    private(set) var droppedBuffers = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: RemoteAudio.pcmFormat)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // 例如插拔耳機、切換 AirPods：引擎會停止，需重新啟動
            self?.queue.async { self?.running = false; self?.queuedFrames = 0 }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    func handle(_ data: Data) {
        queue.async { [weak self] in self?.play(data) }
    }

    /// 斷線 / 重連 / 關閉聲音時清空
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.node.stop()
            self.queuedFrames = 0
            self.decoder?.reset()
            if self.running { self.node.play() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.node.stop()
            self.engine.stop()
            self.running = false
            self.queuedFrames = 0
            self.decoder?.reset()
        }
    }

    private func play(_ data: Data) {
        guard let packet = AudioPacket(data: data), let buffer = decoder?.decode(packet.packets) else { return }
        onDecoded?(buffer)
        guard outputEnabled else { return }
        guard startIfNeeded() else { return }

        let latency = Double(queuedFrames) / RemoteAudio.sampleRate
        if latency > Self.maxLatency {
            droppedBuffers += 1
            return
        }
        queuedFrames += buffer.frameLength
        let frames = buffer.frameLength
        node.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.queuedFrames = self.queuedFrames > frames ? self.queuedFrames - frames : 0
            }
        }
    }

    private func startIfNeeded() -> Bool {
        if running && engine.isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // playback：靜音開關打開也會出聲；mixWithOthers：不打斷 iPad 上其他 App 的聲音
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            node.play()
            running = true
            queuedFrames = 0
            return true
        } catch {
            return false
        }
    }
}
