import CoreMedia
import CoreVideo
import VideoToolbox

/// 映像を VideoToolbox でデコードする。表示の層に圧縮したまま渡すと、いつ映ったかを知る手段が無く、
/// デコードが遅れたまま映し続けても気づけない (開き直すまでずれが溜まる)。デコードしたコマなら、
/// 表示の時刻に間に合ったかをこちらで見られる。
/// `media` の列で呼ぶ。できたコマも `media` の列で `onFrame` に渡す。
nonisolated final class VideoDecoder: @unchecked Sendable {
    /// デコードしたコマ (表示の時刻付き)
    private let onFrame: @Sendable (sending CMSampleBuffer) -> Void
    /// デコードの失敗 (コマ単位)
    private let onFailure: @Sendable (OSStatus) -> Void
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    /// flush ごとに進める。flush の前に頼んだコマが後から届いたら捨てる
    private var epoch = 0

    init(onFrame: @escaping @Sendable (sending CMSampleBuffer) -> Void, onFailure: @escaping @Sendable (OSStatus) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// 圧縮したコマを 1 つデコードに回す。`display` が false なら、デコードだけして映さない (参照に使うコマ)
    func decode(_ sample: CMSampleBuffer, display: Bool) {
        guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { return }
        var status = decodeFrame(sample, format: sampleFormat, display: display)
        if status == kVTInvalidSessionErr {
            // 裏へ回ると session が使えなくなる。作り直してもう一度だけ
            invalidate()
            status = decodeFrame(sample, format: sampleFormat, display: display)
        }
        if status != noErr { onFailure(status) }
    }

    /// 頼んだコマを捨てる。以後に届く前のコマは渡さない
    func flush() {
        epoch += 1
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    private func decodeFrame(_ sample: CMSampleBuffer, format sampleFormat: CMFormatDescription, display: Bool) -> OSStatus {
        if let session, let format, !CMFormatDescriptionEqual(format, otherFormatDescription: sampleFormat),
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: sampleFormat) {
            invalidate()
        }
        if session == nil {
            let status = makeSession(sampleFormat)
            guard status == noErr else { return status }
        }
        guard let session else { return kVTInvalidSessionErr }
        let epoch = epoch
        let onFrame = onFrame
        let onFailure = onFailure
        return VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, image, pts, duration in
            guard status == noErr else {
                MediaQueue.media.async { [weak self] in
                    guard let self, self.epoch == epoch else { return }
                    onFailure(status)
                }
                return
            }
            // 落としたコマ (kVTDecodeInfo_FrameDropped) は image が無い
            guard display, let image, let made = Self.frame(image, pts: pts, duration: duration) else { return }
            // ここで作ったコマを media の列へ 1 度だけ渡す (ほかからは触らない)
            nonisolated(unsafe) let frame = made
            MediaQueue.media.async { [weak self] in
                guard let self, self.epoch == epoch else { return }
                onFrame(frame)
            }
        }
    }

    private func makeSession(_ sampleFormat: CMFormatDescription) -> OSStatus {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: sampleFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        session = created
        format = created == nil ? nil : sampleFormat
        return status
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private static func frame(_ image: CVImageBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }
}
