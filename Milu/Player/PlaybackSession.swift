import AVFoundation
import Foundation
import Observation
import UIKit
import os

/// ライブの再生 (3.3)。開く・繋ぎ直し・音声・画質・字幕・裏に回ったときを受け持つ。
/// 繋ぎ直しの分岐は `LivePlaybackPolicy` に置き、ここは通信と画面の世話をする。
@Observable
@MainActor
final class PlaybackSession {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case loading
        case reconnecting
        case playing
        case paused
        case stopped
    }

    struct Stop: Equatable {
        var reason: LiveStopReason
        var retry: Bool
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var service: Service?
    private(set) var phase: Phase = .idle
    private(set) var rendererState = RendererState()
    private(set) var currentCodec: OfferCodec?
    private(set) var qualityItems: [PlaybackRules.QualityItem] = []
    private(set) var selectedQuality: OfferCodec?
    /// 選んだ解像度の段 (0 は元のまま)。端末ごとに覚える
    private(set) var selectedRung = 0
    private(set) var audioTracks: [AudioTrack] = []
    private(set) var selectedAudio: AudioTrack?
    private(set) var stop: Stop?
    private(set) var showReconnect = false
    private(set) var hasCaptions = false
    private(set) var captionPage: CaptionPage?
    private(set) var captionsOn: Bool
    /// 端末が PiP に対応していれば作る (#48)。`nil` ならボタンを出さない
    private(set) var pictureInPicture: PictureInPicture?
    private(set) var pictureInPictureActive = false

    private let baseURL: URL
    private var token: String?
    private let defaults: UserDefaults
    private let nowPlaying: NowPlayingController
    private let nowPlayingID = UUID()
    private let onInvalidToken: @MainActor (URL) -> Void
    private let onNeedsPairing: @MainActor (URL) -> Void

    private var liveCodecs: [OfferCodec] = []
    /// 端末の `P`。開くたびに `playable` をここへ戻す (テストでは差し替える)
    private let devicePlayable: [OfferCodec]
    private var playable: [OfferCodec]
    private var policy: LivePlaybackPolicy
    private var renderer: MediaRenderer?
    private var loader: StreamLoader?
    private var captionSource: CaptionSource?
    private var captionTimeline = CaptionTimeline()
    /// 映像の応答が返した段。字幕も同じ段を渡して、同じストリームを共有する
    private var rung: String?
    /// いまのストリームの段。続けられる今の接続 (再生中) があれば、選んだ段 (`selectedRung`) を試し、
    /// 採用したとき (200・受け取れる形式・初期化と最初の映像の標本) にここへ移して保存する。
    /// 無いとき (一時停止・開いている途中・止まった画面) は、選んだその場でここへ移して保存する
    private var committedRung = 0
    /// 段を試している接続。今のストリームは閉じずに続け、200 が返ってから切り替える
    /// (denpa の api.md「rung」: 混んでいて断られたら今のストリームをそのまま続ける)
    private var trialLoader: StreamLoader?
    private let startLoader: (StreamLoader) -> Void
    private var captionQueue: [(page: CaptionPage, time: Double)] = []
    private var shownCaptionTime: Double?
    private var connectionTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    /// 閉じたあと・開き直したあとに届いた古いコールバックを捨てる印
    private(set) var generation = 0
    private var closed = false
    private(set) var inBackground = false
    private(set) var videoEpoch = 0
    private var firstFrameSeen = false
    private var handledDecodeFailure = false
    private var bufferedSince: Date?
    private var lastPosition = 0.0
    private var lastProgressAt = Date()

    init(
        baseURL: URL,
        token: String?,
        defaults: UserDefaults = .standard,
        nowPlaying: NowPlayingController = .shared,
        onInvalidToken: @escaping @MainActor (URL) -> Void,
        onNeedsPairing: @escaping @MainActor (URL) -> Void,
        playable: [OfferCodec] = Playable.formats,
        startLoader: @escaping (StreamLoader) -> Void = { $0.start() }
    ) {
        self.devicePlayable = playable
        self.playable = playable
        self.policy = LivePlaybackPolicy(playable: playable)
        self.startLoader = startLoader
        self.baseURL = baseURL
        self.token = token
        self.defaults = defaults
        self.nowPlaying = nowPlaying
        self.onInvalidToken = onInvalidToken
        self.onNeedsPairing = onNeedsPairing
        self.captionsOn = defaults.object(forKey: "captionsOn") as? Bool ?? true
    }

    /// 画面の `onAppear` で 1 度だけ。レンダラをここで作る (MainActor の init)
    func setUp() {
        guard renderer == nil else { return }
        let created = MediaRenderer(displayLayer: displayLayer) { [weak self] state in
            Task { @MainActor in self?.receive(state) }
        }
        created.setVideoEnabled(!inBackground, epoch: videoEpoch)
        renderer = created
        // ライブはタイムシフトが無いので、窓にスキップを出さない (D17)
        pictureInPicture = PictureInPicture(displayLayer: displayLayer, source: self, linear: true)
    }

    func open(_ service: Service, liveCodecs: [OfferCodec]) {
        setUp()
        // 選局したら前の局の窓は閉じる (#48)
        stopPictureInPicture()
        closed = false
        generation += 1
        self.service = service
        self.liveCodecs = liveCodecs
        playable = devicePlayable
        policy = LivePlaybackPolicy(playable: playable)
        currentCodec = nil
        cancelTrial()
        committedRung = PlaybackRules.resolveRung(defaults.integer(forKey: "liveRung"))
        selectedRung = committedRung
        audioTracks = service.now?.audios ?? []
        selectedAudio = PlaybackRules.pickAudio(
            tracks: audioTracks,
            savedName: defaults.string(forKey: "liveAudioName")
        )
        rebuildQualityMenu()
        startStream(resetPolicy: true)
        if nowPlaying.currentOwner == nowPlayingID {
            publishNowPlaying(isPlaying: true)
        }
    }

    func updateService(_ service: Service) {
        self.service = service
        let tracks = service.now?.audios ?? []
        let picked = PlaybackRules.pickAudio(
            tracks: tracks,
            savedName: selectedAudio?.label ?? defaults.string(forKey: "liveAudioName")
        )
        audioTracks = tracks
        // 停止後 (.stopped / .idle) に SSE の一覧更新が届いても、閉じた接続を開き直したり Now Playing を書き戻したりしない
        guard !closed, stop == nil, phase != .stopped, phase != .idle else { return }
        if picked?.id != selectedAudio?.id {
            selectedAudio = picked
            if phase != .paused {
                startStream(resetPolicy: false)
            }
        }
        if nowPlaying.currentOwner == nowPlayingID {
            publishNowPlaying(isPlaying: phase != .paused)
        }
    }

    func selectQuality(_ codec: OfferCodec?) {
        guard codec != selectedQuality else { return }
        selectedQuality = codec
        if let codec {
            defaults.set(codec.rawValue, forKey: "liveQuality")
        } else {
            defaults.removeObject(forKey: "liveQuality")
        }
        guard !closed, stop == nil, phase != .paused, phase != .stopped, phase != .idle else { return }
        startStream(resetPolicy: true)
    }

    /// 音声だけの観方では空 (解像度の欄を出さない)
    var rungItems: [PlaybackRules.RungItem] { PlaybackRules.rungMenu(currentCodec: currentCodec) }

    /// いま開いているストリームの URL (テストで `rung=` などを確かめる)
    var currentStreamURL: URL? { loader?.url }

    func selectRung(_ rung: Int) {
        guard PlaybackRules.isRung(rung), rung != selectedRung else { return }
        if trialLoader != nil, rung == committedRung {
            // 今流れている段に選び直した。試しを捨てるだけで、今の接続はそのまま
            cancelTrial()
            return
        }
        guard let service, !closed, stop == nil, phase == .playing else {
            // 映しているストリームが無い (一時停止は接続を閉じている)。試さずにそのまま選ぶ
            cancelTrial()
            selectedRung = rung
            commitRung()
            if !closed, stop == nil, phase == .loading || phase == .reconnecting {
                startStream(resetPolicy: true)
            }
            return
        }
        // 試している間に選び直したら、試している接続だけ捨てて新しいほうを試す
        trialLoader?.cancel()
        selectedRung = rung
        let trial = makeLoader(url: liveURL(service: service, rung: rung), holding: true)
        trialLoader = trial
        Self.logger.info("live try rung=\(rung, privacy: .public)")
        startLoader(trial)
    }

    /// 選んだ段をいまのストリームの段にし、端末に覚える (「元のまま」なら消す)
    private func commitRung() {
        committedRung = selectedRung
        if committedRung == 0 {
            defaults.removeObject(forKey: "liveRung")
        } else {
            defaults.set(committedRung, forKey: "liveRung")
        }
    }

    /// 試している接続を捨て、選択をいまのストリームの段に戻す
    private func cancelTrial() {
        trialLoader?.cancel()
        trialLoader = nil
        selectedRung = committedRung
    }

    /// 試した段が 200 を返し、受け取れる形式で初期化と最初の映像の標本が届いた。ここで初めて今の接続を閉じて切り替える
    private func adoptTrial(_ trial: StreamLoader, codec: String?, rung: String?) {
        trialLoader = nil
        commitRung()
        Self.logger.info("live switch rung=\(self.committedRung, privacy: .public)")
        policy = LivePlaybackPolicy(playable: playable)
        phase = .loading
        attach(trial)
        // レンダラの reset のあとに溜めていた標本を渡す (どちらも media の列で順に走る)
        trial.release()
        handleResponse(codec, rung: rung)
    }

    /// 試した段が断られた (混んでいる・失敗)。再試行せず、今のストリームを続ける
    private func rejectTrial(_ trial: StreamLoader, reason: String) {
        trial.cancel()
        trialLoader = nil
        Self.logger.info("live rung=\(self.selectedRung, privacy: .public) refused (\(reason, privacy: .public)); keep rung=\(self.committedRung, privacy: .public)")
        selectedRung = committedRung
    }

    func selectAudio(_ track: AudioTrack) {
        guard track.id != selectedAudio?.id else { return }
        selectedAudio = track
        if !track.label.isEmpty {
            defaults.set(track.label, forKey: "liveAudioName")
        }
        guard !closed, stop == nil, phase != .paused, phase != .stopped, phase != .idle else { return }
        startStream(resetPolicy: true)
    }

    func setCaptionsOn(_ on: Bool) {
        captionsOn = on
        defaults.set(on, forKey: "captionsOn")
        updateCaption()
    }

    func retry() {
        guard stop != nil else { return }
        stop = nil
        startStream(resetPolicy: true)
    }

    func close() {
        closed = true
        cancelTrial()
        generation += 1
        stopPictureInPicture()
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        captionSource?.stop()
        captionSource = nil
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        UIApplication.shared.isIdleTimerDisabled = false
        DisplayMode.reset()
        phase = .idle
        stop = nil
        showReconnect = false
        captionPage = nil
    }

    /// 裏に回っている間は映像の層だけ止め、接続と音は保つ (#32)。PiP の窓に出ている間は映像も流す (#48)
    func setBackground(_ background: Bool) {
        guard inBackground != background else { return }
        inBackground = background
        videoEpoch += 1
        applyVideoState()
        UIApplication.shared.isIdleTimerDisabled = !background && phase == .playing
    }

    private func applyVideoState() {
        renderer?.setVideoEnabled(
            PlaybackRules.videoEnabled(inBackground: inBackground, pictureInPicture: pictureInPictureActive),
            epoch: videoEpoch
        )
    }

    /// PiP のボタンを出すか
    var canPictureInPicture: Bool { pictureInPicture != nil }

    func togglePictureInPicture() {
        pictureInPicture?.toggle()
    }

    private func stopPictureInPicture() {
        pictureInPicture?.stop()
    }

    @discardableResult
    func play() -> Bool {
        guard service != nil, !closed, stop == nil else { return false }
        if phase == .paused {
            startStream(resetPolicy: true)
            publishNowPlaying(isPlaying: true)
            pictureInPicture?.invalidatePlaybackState()
        }
        return true
    }

    /// ライブにはタイムシフトが無い (D17) ので、一時停止で接続を閉じてチューナーを空ける。
    @discardableResult
    func pause() -> Bool {
        guard service != nil, !closed, stop == nil else { return false }
        guard phase == .playing || phase == .loading || phase == .reconnecting else {
            return phase == .paused
        }
        // 試している間に一時停止したら、試しは捨てて選んだ段をその場で確定・保存する
        // (接続の無い一時停止中に選んだときと同じ。再開でその段で開く)
        if trialLoader != nil {
            trialLoader?.cancel()
            trialLoader = nil
            commitRung()
        }
        generation += 1
        phase = .paused
        firstFrameSeen = false
        showReconnect = false
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        captionSource?.stop()
        captionSource = nil
        captionPage = nil
        renderer?.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        publishNowPlaying(isPlaying: false)
        pictureInPicture?.invalidatePlaybackState()
        return true
    }

    @discardableResult
    func togglePlayPause() -> Bool {
        if phase == .paused {
            return play()
        }
        return pause()
    }

    private func publishNowPlaying(isPlaying: Bool) {
        guard let service, !closed, stop == nil, phase != .stopped, phase != .idle else { return }
        guard nowPlaying.currentOwner == nil || nowPlaying.currentOwner == nowPlayingID else { return }
        nowPlaying.update(
            owner: nowPlayingID,
            item: .live(service: service, isPlaying: isPlaying),
            onPlay: { [weak self] in self?.play() ?? false },
            onPause: { [weak self] in self?.pause() ?? false },
            onToggle: { [weak self] in self?.togglePlayPause() ?? false }
        )
    }

    func yielded() {
        handlePolicy(.yielded, at: Date())
    }


    func captionHidden(_ run: CaptionRun) -> Bool {
        guard captionsOn else { return true }
        return captionTimeline.isHidden(run, at: rendererState.timeline * 1000)
    }

    // MARK: - 開く・繋ぎ直す

    private func startStream(resetPolicy: Bool) {
        closed = false
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        captionSource?.stop()
        captionSource = nil
        captionTimeline = CaptionTimeline()
        captionPage = nil
        hasCaptions = false
        showReconnect = false
        stop = nil
        rendererState = RendererState()
        firstFrameSeen = false
        handledDecodeFailure = false
        bufferedSince = nil
        lastPosition = 0
        lastProgressAt = Date()
        if resetPolicy {
            policy = LivePlaybackPolicy(playable: playable)
        }
        guard !playable.isEmpty else {
            finish(.noPlayableFormat, retry: false)
            return
        }
        phase = .loading
        openStream()
    }

    private func openStream() {
        guard let service, stop == nil, !closed else { return }
        cancelTrial()
        let url = liveURL(service: service, rung: committedRung)
        Self.logger.info("live open service=\(service.id, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        let loader = makeLoader(url: url, holding: false)
        attach(loader)
        startLoader(loader)
    }

    /// 前の接続を止めてレンダラを作り直し、`loader` をいまの接続にする
    private func attach(_ loader: StreamLoader) {
        // 前の接続を必ず止める。止めないと古い標本が同じレンダラに混ざる
        connectionTask?.cancel()
        connectionTask = nil
        self.loader?.cancel()
        self.loader = nil
        captionSource?.stop()
        captionSource = nil
        generation += 1
        // 繋ぎ直しのたびに、最初のコマ待ちの状態をやり直す
        firstFrameSeen = false
        handledDecodeFailure = false
        rendererState = RendererState()
        bufferedSince = nil
        lastPosition = 0
        lastProgressAt = Date()
        captionTimeline = CaptionTimeline()
        captionPage = nil
        hasCaptions = false
        rung = nil
        captionQueue = []
        shownCaptionTime = nil
        renderer?.reset(live: true, from: 0, ruler: false, generation: generation)
        self.loader = loader
    }

    /// コールバックは、いまの接続 (`loader`) か試している接続 (`trialLoader`) のものだけを受ける。
    /// 閉じたあと・開き直したあとに届いた古いものは捨てる
    private func makeLoader(url: URL, holding: Bool) -> StreamLoader {
        let loader = StreamLoader(url: url, mode: .live, token: token, holding: holding) { [weak renderer] in
            renderer?.bufferedAhead ?? 0
        }
        // 試しの接続のヘッダは受けない。採用 (onReady) のときに 1 度だけ応答として扱う。
        // ヘッダと onReady の Task の順は決まらないので、採用のあとに遅れたヘッダで字幕を開き直さないように
        if !holding {
            loader.onResponse = { [weak self, weak loader] codec, rung in
                Task { @MainActor in
                    guard let self, let loader, loader === self.loader else { return }
                    self.handleResponse(codec, rung: rung)
                }
            }
        }
        loader.onReady = { [weak self, weak loader] codec, rung in
            Task { @MainActor in
                guard let self, let loader, loader === self.trialLoader else { return }
                // 段を下げた応答はサーバが選んだコーデック。いまの P (デコードできずに外したものを除く) にあるものだけ採用する
                if let parsed = PlaybackRules.liveResponseCodec(codec), self.playable.contains(parsed) {
                    self.adoptTrial(loader, codec: codec, rung: rung)
                } else {
                    self.rejectTrial(loader, reason: "codec=\(codec ?? "-")")
                }
            }
        }
        loader.onInitialization = { [weak renderer] tracks in
            renderer?.handle(.initialization(tracks))
        }
        loader.onSamples = { [weak renderer] samples in
            renderer?.handle(.samples(samples))
        }
        loader.onFailure = { [weak self, weak loader] failure in
            Task { @MainActor in
                guard let self, let loader else { return }
                if loader === self.trialLoader {
                    self.rejectTrial(loader, reason: "status=\(failure.status.map(String.init) ?? "-") \(failure.message ?? "")")
                } else if loader === self.loader {
                    self.handleFailure(failure)
                }
            }
        }
        loader.onFinish = { [weak self, weak loader] empty in
            Task { @MainActor in
                guard let self, let loader else { return }
                if loader === self.trialLoader {
                    self.rejectTrial(loader, reason: "closed")
                } else if loader === self.loader {
                    self.handleFinish(empty: empty)
                }
            }
        }
        return loader
    }

    private func liveURL(service: Service, rung: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "api/services/\(service.id)/live"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = []
        if let selectedQuality {
            items.append(URLQueryItem(name: "codec", value: selectedQuality.rawValue))
        } else {
            items.append(URLQueryItem(name: "codec", value: "auto"))
            items.append(URLQueryItem(name: "playable", value: playable.map(\.rawValue).joined(separator: ",")))
        }
        if let selectedAudio {
            items.append(URLQueryItem(name: "audio", value: selectedAudio.id))
        }
        items += PlaybackRules.rungQueryItems(rung)
        components.queryItems = items
        return components.url!
    }

    private func scheduleRestart(after seconds: Double) {
        // 今の接続が切れて繋ぎ直す。古い条件で作った試しは採用しない
        cancelTrial()
        connectionTask?.cancel()
        overlayTask?.cancel()
        showReconnect = false
        phase = .reconnecting
        let scheduled = generation
        Self.logger.info("live restart in \(seconds, privacy: .public)s")
        connectionTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, let self, !self.closed, self.generation == scheduled else { return }
            self.connectionTask = nil
            self.openStream()
        }
        overlayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.firstFrameSeen else { return }
            self.showReconnect = true
        }
    }

    private func finish(_ reason: LiveStopReason, retry: Bool) {
        cancelTrial()
        stop = Stop(reason: reason, retry: retry)
        phase = .stopped
        showReconnect = false
        stopPictureInPicture()
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        captionSource?.stop()
        captionSource = nil
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        UIApplication.shared.isIdleTimerDisabled = false
        DisplayMode.reset()
        Self.logger.info("live stop \(String(describing: reason), privacy: .public)")
    }

    // MARK: - レンダラの状態

    /// テストからも呼ぶ (古い世代の「映った」で待ちを消さないこと)
    func receive(_ state: RendererState) {
        guard !closed, stop == nil, phase != .paused, state.generation == generation else { return }
        rendererState = state
        let now = Date()
        // 映像の形式が決まったら、テレビのモードを映像に合わせる (3.3・Apple TV)
        DisplayMode.apply(format: state.format, frameRate: state.frameRate)

        if state.isPlaying, !firstFrameSeen {
            firstFrameSeen = true
            phase = .playing
            showReconnect = false
            overlayTask?.cancel()
            overlayTask = nil
            // 映ったのだから、待っていた再開は要らない
            connectionTask?.cancel()
            connectionTask = nil
            UIApplication.shared.isIdleTimerDisabled = !inBackground
            lastPosition = state.position
            lastProgressAt = now
            handlePolicy(.firstFrame, at: now)
            publishNowPlaying(isPlaying: true)
        }

        // 裏へ回る境目や表へ戻す前の世代で作られた videoFailed は、対応形式の不備ではないので無視する
        if state.videoFailed,
           !inBackground,
           state.videoEpoch == videoEpoch,
           UIApplication.shared.applicationState != .background,
           !handledDecodeFailure {
            handledDecodeFailure = true
            if let codec = currentCodec {
                handlePolicy(.decodeFailed(codec: codec), at: now)
            } else {
                handlePolicy(.stalled, at: now)
            }
            return
        }

        if !state.isPlaying {
            // 1 秒溜まっているのに映らない (デコードできない) と、何も溜まらずに
            // 最初のコマが来ない (選局待ち)。15 秒の判定はどちらか 1 つだけにする (3.3)
            if bufferedSince == nil { bufferedSince = now }
            if now.timeIntervalSince(bufferedSince!) >= 15, !handledDecodeFailure {
                handledDecodeFailure = true
                if state.buffered >= 1, let codec = currentCodec {
                    handlePolicy(.decodeFailed(codec: codec), at: now)
                } else {
                    handlePolicy(.stalled, at: now)
                }
                return
            }
        } else {
            bufferedSince = nil
        }

        if state.isPlaying {
            if abs(state.position - lastPosition) >= 0.1 {
                lastPosition = state.position
                lastProgressAt = now
            } else if now.timeIntervalSince(lastProgressAt) >= 10 {
                lastProgressAt = now
                handlePolicy(.stalled, at: now)
                return
            }
        }
        updateCaption()
    }

    private func handleResponse(_ codec: String?, rung: String?) {
        guard !closed, stop == nil else { return }
        guard let codec, let parsed = PlaybackRules.liveResponseCodec(codec) else {
            Self.logger.error("live unsupported codec \(codec ?? "-", privacy: .public)")
            finish(.noPlayableFormat, retry: true)
            return
        }
        currentCodec = parsed
        self.rung = rung
        Self.logger.info("live response codec=\(codec, privacy: .public) rung=\(rung ?? "-", privacy: .public)")
        handlePolicy(.response, at: Date())
        startCaptions(codec: codec)
    }

    /// テストからも呼ぶ (close のあとに届いた失敗で再開しないこと)
    func handleFailure(_ failure: StreamFailure) {
        guard !closed, stop == nil else { return }
        if failure.status == 401 {
            switch failure.errorCode {
            case "invalid_token":
                onInvalidToken(baseURL)
                token = nil
                startStream(resetPolicy: false)
            default:
                onNeedsPairing(baseURL)
                finish(.refused(failure.message ?? String(localized: "認証が必要です")), retry: false)
            }
            return
        }
        handlePolicy(.failed(status: failure.status, message: failure.message, errorCode: failure.errorCode), at: Date())
    }

    private func handleFinish(empty: Bool) {
        guard !closed, stop == nil else { return }
        handlePolicy(empty ? .empty : .closed, at: Date())
    }

    private func handlePolicy(_ event: LiveEvent, at now: Date) {
        for action in policy.handle(event, at: now) {
            switch action {
            case .restartNow:
                scheduleRestart(after: 0)
            case .restart(let seconds):
                scheduleRestart(after: seconds)
            case .resetWait:
                break
            case .removeCodec(let codec):
                cancelTrial()
                playable.removeAll { $0 == codec }
                policy = LivePlaybackPolicy(playable: playable, currentCodec: currentCodec)
                rebuildQualityMenu()
            case .stop(let reason, let retry):
                finish(reason, retry: retry)
            }
        }
    }

    // MARK: - 画質・字幕

    private func rebuildQualityMenu() {
        qualityItems = PlaybackRules.liveQualityMenu(liveCodecs: liveCodecs, playable: playable)
        let saved = defaults.string(forKey: "liveQuality").flatMap(OfferCodec.init(rawValue:))
        selectedQuality = PlaybackRules.resolveQuality(saved: saved, menu: qualityItems)
    }

    private func startCaptions(codec: String) {
        captionSource?.stop()
        captionTimeline = CaptionTimeline()
        captionPage = nil
        captionQueue = []
        shownCaptionTime = nil
        guard let service else { return }
        let source = CaptionSource(
            baseURL: baseURL,
            token: token,
            serviceID: service.id,
            codec: codec,
            audioID: selectedAudio?.id,
            rung: rung
        ) { [weak self] frame in
            self?.handleCaption(frame)
        }
        captionSource = source
        source.start()
    }

    private func handleCaption(_ frame: CaptionFrame) {
        guard case .page(let page) = frame.content else { return }
        hasCaptions = true
        // 変換したライブのページの時刻は、映像と同じ fMP4 の時刻 (4.4・api.md)
        enqueueCaption(page, at: Double(frame.timestamp90kHz) / 90000)
    }

    private func enqueueCaption(_ page: CaptionPage, at time: Double) {
        captionQueue.append((page, time))
        captionQueue.sort { $0.time < $1.time }
        if captionQueue.count > 20 {
            captionQueue.removeFirst(captionQueue.count - 20)
        }
        updateCaption()
    }

    private func updateCaption() {
        guard captionsOn else {
            captionPage = nil
            return
        }
        let timeline = rendererState.timeline
        if let candidate = captionQueue.last(where: { $0.time <= timeline + 0.05 }),
           candidate.time != shownCaptionTime {
            shownCaptionTime = candidate.time
            // ライブのページは映像より数秒遅れて届くことがある。届いた時刻から duration を数える
            captionTimeline.show(candidate.page, at: timeline * 1000)
        }
        captionQueue.removeAll { $0.time < timeline - 10 }
        captionPage = captionTimeline.page(at: timeline * 1000)
    }
}

// MARK: - ピクチャ・イン・ピクチャ (#48)

extension PlaybackSession: PictureInPicture.Source {
    var isPictureInPicturePaused: Bool { PlaybackRules.pictureInPictureIsPaused(phase: phase) }

    /// ライブは終わりが無い (D17)。スキップも出さないので、範囲だけ無限にする
    var pictureInPictureTimeRange: CMTimeRange { PlaybackRules.livePictureInPictureTimeRange }

    /// 窓の一時停止は「止める」と同じ。再開したらその時点のライブに戻る (D17)
    func setPictureInPicturePlaying(_ playing: Bool) {
        if playing {
            _ = play()
        } else {
            _ = pause()
        }
    }

    func skipPictureInPicture(by seconds: Double) {}

    func pictureInPictureDidChange(_ active: Bool) {
        pictureInPictureActive = active
        // 裏にいる間に窓が開いた・閉じたときは、映像の止め方が変わる
        if inBackground {
            videoEpoch += 1
            applyVideoState()
        }
    }
}
