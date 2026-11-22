import Foundation
import AVFoundation
import UIKit

/// H.264 封包 → CMSampleBuffer → AVSampleBufferDisplayLayer（硬體解碼、低延遲）
final class VideoRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onSizeChange: ((CGSize) -> Void)?
    var onNeedKeyframe: (() -> Void)?

    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private let lock = NSLock()

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// 重新連線時呼叫：保留最後一張畫面，但等待新的關鍵幀
    func prepareForNewStream() {
        lock.withLock { awaitingKeyframe = true }
    }

    /// 可在任一（單一）背景佇列呼叫
    func handle(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let packet = VideoPacket(data: data) else { return }
        let renderer = displayLayer.sampleBufferRenderer

        if renderer.status == .failed {
            // 例如 App 進入背景後解碼器失效
            renderer.flush()
            awaitingKeyframe = true
        }

        if packet.isKeyframe, !packet.parameterSets.isEmpty,
           let newFormat = makeFormat(packet.parameterSets) {
            if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: newFormat) {
                format = newFormat
                let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
                onSizeChange?(CGSize(width: Int(dims.width), height: Int(dims.height)))
            }
            awaitingKeyframe = false
        }

        guard let format, !awaitingKeyframe else {
            onNeedKeyframe?()
            return
        }
        guard let sample = makeSample(packet.payload, format: format) else { return }
        renderer.enqueue(sample)
    }

    private func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        let pointers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: constPointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private func makeSample(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = payload.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
