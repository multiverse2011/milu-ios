import AVFAudio
import AVFoundation
import CoreMedia
import os

/// 画面へ送る値。MainActor へはこの Sendable な struct だけを渡す (D11)。
nonisolated struct RendererState: Sendable {
    var isPlaying = false
    var codec = ""
    var position: Double = 0
    /// シンクロナイザの生の時刻 (ライブは受け取った fMP4 の PTS。字幕の時刻はこれで比べる)
    var timeline: Double = 0
    var buffered: Double = 0
    /// 録画の HTTP 終端を受け、再生できる末尾の映像を消化した。
    var recordingEndDrained = false
    var message: String?
    /// 映像のデコード・描画が失敗した (音声だけの失敗とは分ける)
    var videoFailed = false
    /// `reset` ごとの番号。開き直す前の状態を捨てるのに使う
    var generation = 0
    /// `setVideoEnabled` ごとの番号。裏へ回る境目の古い `videoFailed` を捨てるのに使う
    var videoEpoch = 0
    /// 表へ戻ったとき、手元の控えだけではいまの時刻の映像を埋められなかった (録画・追っかけの開き直し用)
    var videoGap = false
    /// 映像の形式。決まったら Apple TV の表示のモードを合わせるのに使う (3.3)
    var format: CMFormatDescription?
    /// 映像のコマ数 (標本の長さから)。0 なら分からない
    var frameRate: Double = 0
}

/// `AVSampleBufferRenderSynchronizer` に映像と音声のレンダラを付け、標本を渡す (3.2・D11)。
/// すべての状態は `media` の列の上だけで触る。
nonisolated final class MediaRenderer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    let displayLayer: AVSampleBufferDisplayLayer
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let onState: @Sendable (RendererState) -> Void
    /// iOS 27 からは、シンクロナイザに付けた renderer ではなく、この receiver に標本を渡す
    private var videoReceiver: AVSampleBufferVideoRenderer.Receiver?
    private var audioReceiver: AVSampleBufferAudioRenderer.Receiver?

    private var tracks: [UInt32: FMP4Track] = [:]
    private var formats: [UInt32: CMFormatDescription] = [:]
    /// 映像の形式とコマ数。Apple TV の表示のモードを合わせるのに使う (3.3)
    private var videoFormat: CMFormatDescription?
    private var videoFrameRate = 0.0
    private var firstPTS: [UInt32: Double] = [:]
    private var startAt: Double?
    private var lastVideoPTS = 0.0
    private var lastVideoEnd = 0.0
    private var skipVideoUntilKeyframe = false
    /// 遅れの追いつきで flush したあと、次のキーフレームが来るまで映像も音声も捨てる
    private var awaitingKeyframe = false
    /// 飛んだ先のキーフレームより前の音声を捨てる
    private var audioSkipBefore: Double?
    private var started = false
    private var drainingRecordingEnd = false
    private var live = false
    /// fMP4 の PTS がそのまま位置の物差しか (録画の stream)。追っかけは 0 から始まる
    private var ruler = false
    private var from = 0.0
    private var audioFailed = false
    private var videoFailed = false
    private var generation = 0
    /// 自分の代で音の場を有効にしたか (戻すのはそのときだけ)
    private var ownsAudioSession = false
    private var timer: DispatchSourceTimer?
    private var lastReport = Date.distantPast
    private var stopped = false
    /// 裏に回っている間は `false` にし、映像の層へ標本を渡さず音だけ進める (#32)
    private var videoEnabled = true
    private var videoEpoch = 0
    private var videoGap = false
    /// 映像を止めている間と表へ戻した直後のやり直しの間だけ次のキーフレームから控え、表に戻ったときに流し直す (#32)
    private var pendingVideo: [FMP4Sample] = []
    /// 表へ戻った直後に GPU がまだ使えず flush を求められたとき、次の tick でやり直す印 (上限 VideoReplay.maxRetries 回)
    private var needsForegroundReplay = false
    private var foregroundReplayRetries = 0

    @MainActor
    init(displayLayer: AVSampleBufferDisplayLayer, onState: @escaping @Sendable (RendererState) -> Void) {
        self.displayLayer = displayLayer
        self.onState = onState
        // 画面の層とレンダラの結び付けは MainActor で。以後の receiver の使用は media の列だけ
        displayLayer.videoGravity = .resizeAspect
        videoReceiver = synchronizer.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
        audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.setRate(0, time: .zero)
    }

    /// 開くものを切り替える。前の映像と音声を捨てて、時刻と形式を読み直す
    func reset(live: Bool, from: Double, ruler: Bool, generation: Int) {
        MediaQueue.media.async { [self] in
            self.generation = generation
            timer?.cancel()
            timer = nil
            videoReceiver?.flush()
            audioReceiver?.flush()
            synchronizer.setRate(0, time: .zero)
            tracks.removeAll()
            formats.removeAll()
            videoFormat = nil
            videoFrameRate = 0
            firstPTS.removeAll()
            pendingVideo.removeAll()
            needsForegroundReplay = false
            foregroundReplayRetries = 0
            videoGap = false
            startAt = nil
            lastVideoPTS = 0
            lastVideoEnd = 0
            skipVideoUntilKeyframe = false
            awaitingKeyframe = false
            audioSkipBefore = nil
            started = false
            drainingRecordingEnd = false
            audioFailed = false
            videoFailed = false
            stopped = false
            self.live = live
            self.ruler = ruler
            self.from = from
            startTimer()
            report(force: true)
        }
    }

    func stop() {
        MediaQueue.media.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
            synchronizer.setRate(0, time: .zero)
            videoReceiver?.flush()
            audioReceiver?.flush()
            pendingVideo.removeAll()
            needsForegroundReplay = false
            foregroundReplayRetries = 0
            if ownsAudioSession {
                ownsAudioSession = false
                AudioSessionOwner.shared.release()
            }
        }
    }

    /// 音と映像の送り出しを止めるが、音の場 (`AVAudioSession`) は保ったままにする (ロック画面の再開用)
    func pause() {
        MediaQueue.media.async { [self] in
            guard !stopped else { return }
            timer?.cancel()
            timer = nil
            synchronizer.setRate(0, time: synchronizer.currentTime())
            audioReceiver?.flush()
            videoReceiver?.flush()
            pendingVideo.removeAll()
            needsForegroundReplay = false
            foregroundReplayRetries = 0
            started = false
        }
    }

    /// 裏に回っている間は映像の層に標本を渡さず、音だけ進める (#32)。
    /// 表に戻ったら層を flush して、控えておいたキーフレームから映像だけ追い付かせる。
    func setVideoEnabled(_ enabled: Bool, epoch: Int) {
        MediaQueue.media.async { [self] in
            self.videoEpoch = epoch
            guard videoEnabled != enabled else {
                videoGap = false
                if !stopped { report(force: true) }
                return
            }
            videoEnabled = enabled
            videoFailed = false
            videoGap = false
            needsForegroundReplay = false
            foregroundReplayRetries = 0
            guard !stopped else { return }
            videoReceiver?.flush()
            let reported: Bool
            if enabled {
                reported = replayPendingVideo()
            } else {
                pendingVideo.removeAll()
                reported = false
            }
            if !reported {
                report(force: true)
            }
        }
    }

    /// 再生の速さ (録画の一時停止・倍速)。1 で等速
    func setRate(_ rate: Double) {
        MediaQueue.media.async { [self] in
            guard !stopped else { return }
            if rate > 0, ownsAudioSession {
                AudioSessionOwner.shared.ensureActive()
            }
            synchronizer.setRate(Float(rate), time: synchronizer.currentTime())
        }
    }

    /// いまの再生位置より先に溜まっている秒。録画・追っかけの `suspend` の判断に使う
    var bufferedAhead: Double {
        let now = started ? synchronizer.currentTime().seconds : (startAt ?? 0)
        return max(0, lastVideoEnd - now)
    }

    // MARK: - 標本を渡す

    func handle(_ event: FMP4Event) {
        switch event {
        case .initialization(let tracks):
            updateFormats(tracks)
        case .samples(let samples):
            for sample in samples { enqueue(sample) }
        }
    }

    private func updateFormats(_ updated: [FMP4Track]) {
        tracks = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        formats.removeAll()
        videoFormat = nil
        videoFrameRate = 0
        pendingVideo.removeAll()
        for track in updated {
            guard let format = makeFormatDescription(track) else {
                report(message: String(localized: "この形式の映像を用意できません (\(track.codec))"), force: true)
                continue
            }
            formats[track.id] = format
            if track.kind == .video { videoFormat = format }
        }
    }

    private func enqueue(_ sample: FMP4Sample) {
        guard let track = tracks[sample.trackID], let format = formats[sample.trackID] else { return }
        let seconds = Double(sample.pts) / Double(track.timescale)
        let duration = Double(sample.duration) / Double(track.timescale)

        if let first = firstPTS[sample.trackID] {
            firstPTS[sample.trackID] = min(first, seconds)
        } else {
            firstPTS[sample.trackID] = seconds
        }
        if startAt == nil {
            let earliest = firstPTS.values.min() ?? seconds
            // 録画の stream は PTS が物差しの時刻。追っかけとライブは 0 から始まる
            startAt = ruler ? max(from, earliest) : earliest
        }

        // from の切り落としは、PTS が物差しの時刻である録画の stream だけ。
        // 追っかけの tfdt は 0 から始まるので、from で切ると頭の from 秒が丸ごと消える
        let beforeFrom = ruler && seconds < from - 0.001

        if track.kind == .audio {
            guard !audioFailed, !awaitingKeyframe, !beforeFrom else { return }
            if let audioSkipBefore, seconds < audioSkipBefore - 0.001 { return }
            guard let buffer = makeSampleBuffer(sample, format: format) else { return }
            enqueueAudio(buffer)
            return
        }

        // 1 コマの長さからコマ数を出す (Apple TV の表示のモード。3.3)
        if duration > 0 { videoFrameRate = 1 / duration }

        if awaitingKeyframe {
            guard sample.isKeyframe else { return }
            // 捨てたあとの最初のキーフレームに時刻を合わせて、そこから映し直す
            awaitingKeyframe = false
            skipVideoUntilKeyframe = false
            audioSkipBefore = seconds
            pendingVideo.removeAll()
            synchronizer.setRate(1, time: CMTime(seconds: seconds, preferredTimescale: 600))
            Self.logger.info("live catch-up resumed at \(seconds, privacy: .public)")
        }

        // サーバが媒体を捨てた (続く 2 つの PTS が標本の長さ + 1 秒より離れた)
        if lastVideoEnd > 0, seconds - lastVideoEnd > 1.0 {
            skipVideoUntilKeyframe = true
            pendingVideo.removeAll()
        }
        if !videoEnabled || needsForegroundReplay {
            let now = started ? synchronizer.currentTime().seconds : (startAt ?? 0)
            VideoReplay.append(sample, to: &pendingVideo, now: now) { sampleSeconds($0) }
        }
        guard videoEnabled else {
            lastVideoPTS = seconds
            lastVideoEnd = seconds + duration
            startIfReady()
            return
        }
        if skipVideoUntilKeyframe, !sample.isKeyframe { return }
        if sample.isKeyframe { skipVideoUntilKeyframe = false }

        guard !beforeFrom else {
            // 録画の stream で from より手前はデコードだけさせる
            if let buffer = makeSampleBuffer(sample, format: format, doNotDisplay: true) {
                enqueueVideo(buffer)
            }
            lastVideoPTS = seconds
            lastVideoEnd = seconds + duration
            return
        }

        guard let buffer = makeSampleBuffer(sample, format: format) else { return }
        guard enqueueVideo(buffer) else { return }
        lastVideoPTS = seconds
        lastVideoEnd = seconds + duration
        startIfReady()
    }

    /// 末尾の標本を受け取り終えたら、通常の 1 秒の先読みを満たさなくても再生する。
    func drainRecordingEnd(generation: Int) {
        MediaQueue.media.async { [self] in
            guard self.generation == generation, !stopped else { return }
            drainingRecordingEnd = true
            startIfReady()
            report(force: true)
        }
    }

    private func startIfReady() {
        if !started, let startAt,
           lastVideoPTS >= startAt + 1.0
            || (drainingRecordingEnd && lastVideoPTS >= startAt - 0.001 && lastVideoEnd > startAt) {
            started = true
            activateAudio()
            synchronizer.setRate(1, time: CMTime(seconds: startAt, preferredTimescale: 600))
            Self.logger.info("play at \(startAt, privacy: .public)")
            report(force: true)
        }
    }

    private func sampleSeconds(_ sample: FMP4Sample) -> Double? {
        guard let track = tracks[sample.trackID], track.timescale > 0 else { return nil }
        return Double(sample.pts) / Double(track.timescale)
    }

    @discardableResult
    private func replayPendingVideo() -> Bool {
        let now = started ? synchronizer.currentTime().seconds : (startAt ?? 0)
        let threshold = ruler ? max(from, now) : now
        let chosen = VideoReplay.startIndex(in: pendingVideo, now: threshold, seconds: { sampleSeconds($0) })
            ?? (live ? VideoReplay.firstKeyframeIndex(in: pendingVideo) : nil)
        guard let startIndex = chosen else {
            pendingVideo.removeAll()
            needsForegroundReplay = false
            foregroundReplayRetries = 0
            skipVideoUntilKeyframe = true
            // 録画・追っかけは 20〜30 秒先まで先読みしているため、now を埋められないときはその位置から開き直させる
            if !live, started {
                videoGap = true
                report(force: true)
                return true
            }
            return false
        }
        skipVideoUntilKeyframe = false
        let keyframePTS = pendingVideo[startIndex].pts
        for sample in pendingVideo[startIndex...] {
            if sample.pts < keyframePTS { continue }
            guard
                let track = tracks[sample.trackID],
                track.timescale > 0,
                let format = formats[sample.trackID]
            else { continue }
            let seconds = Double(sample.pts) / Double(track.timescale)
            let duration = Double(sample.duration) / Double(track.timescale)
            let hide = (ruler && seconds < from - 0.001) || (started && seconds + duration <= now)
            guard let buffer = makeSampleBuffer(sample, format: format, doNotDisplay: hide) else { continue }
            if !enqueueVideo(buffer) {
                foregroundReplayRetries += 1
                if VideoReplay.shouldRetryFailure(retryCount: foregroundReplayRetries) {
                    needsForegroundReplay = true
                } else {
                    pendingVideo.removeAll()
                    needsForegroundReplay = false
                    foregroundReplayRetries = 0
                    skipVideoUntilKeyframe = true
                    if !live, started {
                        videoGap = true
                        report(force: true)
                        return true
                    }
                }
                return false
            }
        }
        pendingVideo.removeAll()
        needsForegroundReplay = false
        foregroundReplayRetries = 0
        return false
    }

    /// 映像を渡す。止められたら次のキーフレームまで待つ (`false`)
    @discardableResult
    private func enqueueVideo(_ buffer: sending CMSampleBuffer) -> Bool {
        guard let videoReceiver else { return false }
        switch videoReceiver.enqueueImmediately(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: buffer)) {
        case .enqueued:
            return true
        case .enqueuedWithDecodeFailures(let errors):
            let reason = errors.first?.localizedDescription ?? String(localized: "映像をデコードできません")
            videoFailed = true
            Self.logger.error("video decode failed: \(reason, privacy: .public)")
            report(message: reason, force: true)
            return true
        case .cancelledDueToFlush:
            return true
        case .cancelledDueToFlushRequiredToResume(let error):
            // デコーダが flush を求めている (裏へ回る境目など)。flush して次のキーフレームまで捨てる
            videoReceiver.flush()
            skipVideoUntilKeyframe = true
            Self.logger.info("flush required: \(error.localizedDescription, privacy: .public)")
            return false
        case .cancelledDueToError(let error):
            videoFailed = true
            Self.logger.error("video failed: \(error.localizedDescription, privacy: .public)")
            report(message: error.localizedDescription, force: true)
            return false
        @unknown default:
            return true
        }
    }

    private func enqueueAudio(_ buffer: sending CMSampleBuffer) {
        guard let audioReceiver else { return }
        switch audioReceiver.enqueueImmediately(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: buffer)) {
        case .enqueued:
            break
        case .enqueuedWithSuggestedFlush:
            // 出力の構成が変わった。溜めた音を捨てて続ける
            audioReceiver.flush()
        case .cancelledDueToFlush:
            break
        case .cancelledDueToError(let error):
            audioFailed = true
            Self.logger.error("audio failed: \(error.localizedDescription, privacy: .public)")
            report(message: error.localizedDescription, force: true)
        @unknown default:
            break
        }
    }

    // MARK: - 遅れの追いつき・状態

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: MediaQueue.media)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard started, !stopped else {
            report()
            return
        }
        let now = synchronizer.currentTime().seconds
        if !pendingVideo.isEmpty {
            VideoReplay.trim(&pendingVideo, now: now) { sampleSeconds($0) }
        }
        if videoEnabled, needsForegroundReplay {
            videoReceiver?.flush()
            replayPendingVideo()
        }
        let ahead = lastVideoPTS - now
        if live {
            if awaitingKeyframe {
                report()
                return
            }
            // 4 秒を超えたら速さ 1.05 倍、10 秒を超えたら溜めたものを捨てて次のキーフレームから映し直す (3.2)
            switch CatchUp.action(ahead: ahead, rate: synchronizer.rate) {
            case .flushToKeyframe:
                videoReceiver?.flush()
                audioReceiver?.flush()
                pendingVideo.removeAll()
                awaitingKeyframe = true
                skipVideoUntilKeyframe = true
                synchronizer.setRate(0, time: synchronizer.currentTime())
                Self.logger.info("live catch-up: waiting for a keyframe")
            case .setRate(let rate):
                synchronizer.setRate(Float(rate), time: synchronizer.currentTime())
            case .keep:
                break
            }
        }
        report()
    }

    private func report(message: String? = nil, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.5 else { return }
        lastReport = now
        let gap = videoGap
        // 一度知らせたら、次の setVideoEnabled まで再評価しない
        videoGap = false
        let current = started ? synchronizer.currentTime().seconds : (startAt ?? 0)
        let position: Double
        if live {
            position = max(0, current - (startAt ?? current))
        } else if ruler {
            position = current
        } else if let first = firstPTS.values.min() {
            // 追っかけは fMP4 の時刻が from を土台にしていないので、最初の PTS からの差で数える
            position = from + max(0, current - first)
        } else {
            position = current
        }
        onState(RendererState(
            isPlaying: started,
            codec: tracks.values.first(where: { $0.kind == .video })?.codec ?? "",
            position: position,
            timeline: current,
            buffered: max(0, lastVideoEnd - current),
            recordingEndDrained: drainingRecordingEnd && (!started || current >= lastVideoEnd),
            message: message,
            videoFailed: videoFailed,
            generation: generation,
            videoEpoch: videoEpoch,
            videoGap: gap,
            format: videoFormat,
            frameRate: videoFrameRate
        ))
    }

    private func activateAudio() {
        if ownsAudioSession {
            AudioSessionOwner.shared.ensureActive()
            return
        }
        ownsAudioSession = true
        AudioSessionOwner.shared.activate()
    }

    // MARK: - CoreMedia

    private func makeFormatDescription(_ track: FMP4Track) -> CMFormatDescription? {
        if track.kind == .audio {
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = track.sampleRate > 0 ? track.sampleRate : 48000
            if track.codec == "opus" {
                asbd.mFormatID = kAudioFormatOpus
                asbd.mFormatFlags = 0
                asbd.mFramesPerPacket = 0
            } else {
                asbd.mFormatID = kAudioFormatMPEG4AAC
                asbd.mFormatFlags = UInt32(track.config[track.config.startIndex] >> 3)
                asbd.mFramesPerPacket = 1024
            }
            asbd.mChannelsPerFrame = UInt32(max(1, track.channels))
            var format: CMAudioFormatDescription?
            track.config.withUnsafeBytes { bytes in
                _ = CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: track.config.count,
                    magicCookie: bytes.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
            return format
        }

        let codecType: CMVideoCodecType
        let atom: String
        if track.codec.hasPrefix("avc1") {
            codecType = kCMVideoCodecType_H264
            atom = "avcC"
        } else if track.codec.hasPrefix("hvc1") || track.codec.hasPrefix("hev1") {
            codecType = kCMVideoCodecType_HEVC
            atom = "hvcC"
        } else if track.codec.hasPrefix("av01") {
            codecType = kCMVideoCodecType_AV1
            atom = "av1C"
        } else {
            return nil
        }

        var atoms: [String: Any] = [atom: track.config]
        if let pasp = track.pasp { atoms["pasp"] = pasp }
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
        ]
        // 符号化の寸法のまま、見せる縦横比だけを渡す (1440x1080 の SAR 4:3 を 16:9 に)
        if let pasp = track.pasp, pasp.count >= 8 {
            let horizontal = pasp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let vertical = pasp.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            if horizontal > 0, vertical > 0 {
                extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                    kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: Int(UInt32(bigEndian: horizontal)),
                    kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: Int(UInt32(bigEndian: vertical)),
                ]
            }
        }
        if let color = track.color {
            if let primaries = Self.primaries(color.primaries) {
                extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
            }
            if let transfer = Self.transfer(color.transfer) {
                extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
            }
            if let matrix = Self.matrix(color.matrix) {
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
            }
            extensions[kCMFormatDescriptionExtension_FullRangeVideo] = color.fullRange
        }
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            // 符号化の寸法。表示の縦横比は上の pasp の拡張で渡す
            width: Int32(track.width),
            height: Int32(track.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        if status != noErr { Self.logger.error("format description failed: \(status, privacy: .public)") }
        return format
    }

    private func makeSampleBuffer(
        _ sample: FMP4Sample,
        format: CMFormatDescription,
        doNotDisplay: Bool = false
    ) -> CMSampleBuffer? {
        guard let track = tracks[sample.trackID] else { return nil }
        let size = sample.data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = sample.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: size
            )
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: sample.duration, timescale: CMTimeScale(track.timescale)),
            presentationTimeStamp: CMTime(value: sample.pts, timescale: CMTimeScale(track.timescale)),
            decodeTimeStamp: CMTime(value: sample.dts, timescale: CMTimeScale(track.timescale))
        )
        var sampleSize = size
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }
        if doNotDisplay {
            CMSetAttachment(
                buffer, key: kCMSampleAttachmentKey_DoNotDisplay,
                value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        if !sample.isKeyframe {
            CMSetAttachment(
                buffer, key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return buffer
    }

    private static func primaries(_ value: UInt16) -> CFString? {
        switch value {
        case 1: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9: return kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: return nil
        }
    }

    private static func transfer(_ value: UInt16) -> CFString? {
        switch value {
        case 1: return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    private static func matrix(_ value: UInt16) -> CFString? {
        switch value {
        case 1: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 9: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: return nil
        }
    }
}
