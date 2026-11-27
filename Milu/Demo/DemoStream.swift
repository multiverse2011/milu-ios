import Foundation

private nonisolated final class DemoBundleToken {}

/// 同梱した `demo.mp4` を 1 度だけ demux し、任意の時刻へシフトした標本列を返す。
nonisolated final class DemoVideo: Sendable {
    static let shared: DemoVideo? = DemoVideo.load()

    let tracks: [FMP4Track]
    let fragmentSeconds: Double
    let gopCount: Int

    private let videoTrack: FMP4Track
    private let audioTrack: FMP4Track
    // scripts/make-demo-video.sh の rate=30・-g 32・-ar 48000 (32/30 秒 = 50×1024/48000 秒) に対応
    private let fps: Int64 = 30
    private let gopFrames = 32
    private let audioPerGop = 50
    private let frameTicks: Int64
    private let videoGopTicks: Int64
    private let audioPacketTicks: Int64 = 1024
    private let audioGopTicks: Int64
    private let videoSamples: [FMP4Sample]
    private let audioSamples: [FMP4Sample]

    private init?(data: Data) {
        let demuxer = FMP4Demuxer()
        var parsedTracks: [FMP4Track] = []
        var parsedSamples: [FMP4Sample] = []
        for event in demuxer.feed(data) {
            switch event {
            case .initialization(let value):
                parsedTracks = value
            case .samples(let value):
                parsedSamples.append(contentsOf: value)
            }
        }
        guard
            let vTrack = parsedTracks.first(where: { $0.kind == .video }),
            let aTrack = parsedTracks.first(where: { $0.kind == .audio })
        else { return nil }

        let allVideo = parsedSamples.filter { $0.trackID == vTrack.id }
        let allAudio = parsedSamples.filter { $0.trackID == aTrack.id }
        let count = allVideo.count / gopFrames
        guard count > 0, allAudio.count >= count * audioPerGop else { return nil }

        self.tracks = parsedTracks
        self.videoTrack = vTrack
        self.audioTrack = aTrack
        self.gopCount = count
        self.frameTicks = Int64(vTrack.timescale) / fps
        self.videoGopTicks = Int64(gopFrames) * frameTicks
        self.audioGopTicks = Int64(audioPerGop) * audioPacketTicks
        self.fragmentSeconds = Double(videoGopTicks) / Double(vTrack.timescale)
        self.videoSamples = Array(allVideo.prefix(count * gopFrames))
        // AAC エンコーダが先頭に足すプライミング分を落として周期を映像と一致させる
        let dropAudio = allAudio.count - count * audioPerGop
        self.audioSamples = Array(allAudio.dropFirst(dropAudio).prefix(count * audioPerGop))
    }

    private static func load() -> DemoVideo? {
        let candidates = [Bundle.main, Bundle(for: DemoBundleToken.self)]
        for bundle in candidates {
            if let url = bundle.url(forResource: "demo", withExtension: "mp4"),
               let data = try? Data(contentsOf: url),
               let video = DemoVideo(data: data) {
                return video
            }
        }
        return nil
    }

    /// 通し番号 `fragmentIndex` (0, 1, 2, ...) の 1 GOP ぶんの標本を返す。
    func fragmentSamples(index fragmentIndex: Int, maxSeconds: Double? = nil) -> [FMP4Sample] {
        let gop = ((fragmentIndex % gopCount) + gopCount) % gopCount
        let vBase = Int64(fragmentIndex) * videoGopTicks
        let aBase = Int64(fragmentIndex) * audioGopTicks
        var out: [FMP4Sample] = []
        out.reserveCapacity(gopFrames + audioPerGop)

        let vStart = gop * gopFrames
        for i in 0..<gopFrames {
            let src = videoSamples[vStart + i]
            let pts = vBase + Int64(i) * frameTicks
            if let maxSeconds, Double(pts) / Double(videoTrack.timescale) >= maxSeconds {
                break
            }
            out.append(FMP4Sample(
                trackID: videoTrack.id,
                kind: .video,
                dts: pts,
                pts: pts,
                duration: frameTicks,
                isKeyframe: i == 0 || src.isKeyframe,
                data: src.data
            ))
        }

        let aStart = gop * audioPerGop
        for j in 0..<audioPerGop {
            let src = audioSamples[aStart + j]
            let pts = aBase + Int64(j) * audioPacketTicks
            if let maxSeconds, Double(pts) / Double(audioTrack.timescale) >= maxSeconds {
                break
            }
            out.append(FMP4Sample(
                trackID: audioTrack.id,
                kind: .audio,
                dts: pts,
                pts: pts,
                duration: audioPacketTicks,
                isKeyframe: true,
                data: src.data
            ))
        }
        return out
    }
}

/// `StreamLoader` がデモ URL のときに使うメモリ上のストリーム送り手。
/// すべて `MediaQueue.media` の上だけで動く。
nonisolated final class DemoStream: @unchecked Sendable {
    private let url: URL
    private let mode: StreamLoader.Mode
    private let pace: @Sendable () -> Double
    private let onResponse: (@Sendable (String?, String?) -> Void)?
    private let onInitialization: (@Sendable ([FMP4Track]) -> Void)?
    private let onSamples: (@Sendable ([FMP4Sample]) -> Void)?
    private let onFailure: (@Sendable (StreamFailure) -> Void)?
    private let onFinish: (@Sendable (Bool) -> Void)?

    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var nextFragment = 0
    private var endFragment: Int?
    private var durationSeconds: Double?

    init(
        url: URL,
        mode: StreamLoader.Mode,
        pace: @escaping @Sendable () -> Double,
        onResponse: (@Sendable (String?, String?) -> Void)?,
        onInitialization: (@Sendable ([FMP4Track]) -> Void)?,
        onSamples: (@Sendable ([FMP4Sample]) -> Void)?,
        onFailure: (@Sendable (StreamFailure) -> Void)?,
        onFinish: (@Sendable (Bool) -> Void)?
    ) {
        self.url = url
        self.mode = mode
        self.pace = pace
        self.onResponse = onResponse
        self.onInitialization = onInitialization
        self.onSamples = onSamples
        self.onFailure = onFailure
        self.onFinish = onFinish
    }

    func start() {
        guard !cancelled else { return }
        guard let video = DemoVideo.shared else {
            onFailure?(StreamFailure(status: 500, message: String(localized: "デモ動画を読めません"), errorCode: nil))
            return
        }

        switch mode {
        case .live:
            nextFragment = 0
            endFragment = nil
            durationSeconds = nil
        case .buffered:
            if url.path.hasSuffix("/chase") {
                nextFragment = 0
                endFragment = nil
                durationSeconds = nil
            } else {
                let duration = DemoData.recordingDuration(for: url)
                let requestedFrom = Self.fromQuery(of: url)
                let clampedFrom = min(max(0, requestedFrom), max(0, duration - 1.2))
                let start = max(0, Int(floor(clampedFrom / video.fragmentSeconds)))
                let end = max(start + 1, Int(ceil(duration / video.fragmentSeconds)))
                nextFragment = start
                endFragment = end
                durationSeconds = duration
            }
        }

        onResponse?("h264", nil)
        guard !cancelled else { return }
        onInitialization?(video.tracks)
        guard !cancelled else { return }

        let initialCount = mode == .live ? 2 : 3
        for _ in 0..<initialCount {
            if !emitNext(video: video) {
                return
            }
        }

        if let endFragment, nextFragment >= endFragment {
            onFinish?(false)
            return
        }

        let source = DispatchSource.makeTimerSource(queue: MediaQueue.media)
        source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in
            self?.tick(video: video)
        }
        source.resume()
        timer = source
    }

    func cancel() {
        cancelled = true
        timer?.cancel()
        timer = nil
    }

    private func tick(video: DemoVideo) {
        guard !cancelled else { return }
        let targetAhead: Double = mode == .live ? 2.5 : 15.0
        let maxPerTick = mode == .live ? 2 : 4
        var sent = 0
        while !cancelled, sent < maxPerTick, pace() < targetAhead {
            if !emitNext(video: video) {
                return
            }
            sent += 1
            if let endFragment, nextFragment >= endFragment {
                timer?.cancel()
                timer = nil
                onFinish?(false)
                return
            }
        }
    }

    /// 次の 1 GOP を送る。続けられるなら `true`。
    private func emitNext(video: DemoVideo) -> Bool {
        guard !cancelled else { return false }
        if let endFragment, nextFragment >= endFragment {
            timer?.cancel()
            timer = nil
            onFinish?(false)
            return false
        }
        let samples = video.fragmentSamples(index: nextFragment, maxSeconds: durationSeconds)
        nextFragment += 1
        if !samples.isEmpty {
            onSamples?(samples)
        }
        return !cancelled
    }

    private static func fromQuery(of url: URL) -> Double {
        guard
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let raw = items.first(where: { $0.name == "from" })?.value,
            let value = Double(raw)
        else { return 0 }
        return value
    }
}
