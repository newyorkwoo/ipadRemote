import Foundation
import VideoToolbox
import CoreMedia

/// 低延遲 H.264 硬體編碼
final class H264Encoder {
    var onPacket: ((VideoPacket) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    /// 是否成功使用硬體低延遲模式
    private(set) var isLowLatency = false

    init?(width: Int, height: Int, fps: Int, bitRate: Int) {
        // 優先使用低延遲硬體編碼；不支援時（舊機型、模擬器）退回一般編碼器
        let specs: [CFDictionary?] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            nil,
        ]
        var session: VTCompressionSession?
        var lowLatency = false
        for spec in specs where session == nil {
            let status = VTCompressionSessionCreate(allocator: nil,
                                                    width: Int32(width), height: Int32(height),
                                                    codecType: kCMVideoCodecType_H264,
                                                    encoderSpecification: spec,
                                                    imageBufferAttributes: nil,
                                                    compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil,
                                                    compressionSessionOut: &session)
            if status != noErr { session = nil } else { lowLatency = spec != nil }
        }
        guard let session else { return nil }
        self.session = session

        // 低延遲設定：
        // - 不重排幀、編碼器內不排隊（MaxFrameDelayCount 0），每張畫面一進來就立即輸出
        // - 低延遲模式需用 Constrained High profile
        // - 關鍵幀很大，會造成瞬間塞車；連線走 TCP 不會掉資料，所以只在需要時（連線、切畫質、解碼失敗）才送
        // - 限制每秒資料量上限，避免單一幀暴衝塞住網路
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
                                                              : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_DataRateLimits: [bitRate / 8 * 3 / 2, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 120,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 120,
        ]
        for (key, value) in props {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        isLowLatency = lowLatency
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        let keyframe = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let frameProps: CFDictionary? = keyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                        presentationTimeStamp: presentationTime,
                                        duration: .invalid,
                                        frameProperties: frameProps,
                                        infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var parameterSets: [Data] = []
        if isKeyframe, let format = sampleBuffer.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                                                                   parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size,
                                                                   parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let pointer { parameterSets.append(Data(bytes: pointer, count: size)) }
            }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var payload = Data(count: length)
        let copyStatus = payload.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                       destination: raw.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        onPacket?(VideoPacket(isKeyframe: isKeyframe, parameterSets: parameterSets, payload: payload))
    }
}
