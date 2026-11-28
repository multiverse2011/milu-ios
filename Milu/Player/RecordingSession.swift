import AVFoundation
import Foundation
import Observation
import UIKit
import os

/// 録画を観る (3.3・3.5)。`playback` から観方を選び、`stream` を開く。
/// シーク・続きから・CM 飛ばし・倍速・画質の選び直し・字幕・観た位置を持つ。
/// ライブの `PlaybackSession` とは決まりが違う (繋ぎ直し・字幕の取り方) ので別の型にした。
@Observable
@MainActor
final class RecordingSession {
    /// 録り終えた録画 (`stream`) と、録っている最中の追っかけ (`chase`)
    enum Kind: Equatable {
        case recording
        case chase
    }

    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case reconnecting
        case ended
        case stopped
    }

    struct Stop: Equatable {
        var reason: RecordingStopReason
        var retry: Bool
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    let displayLayer = AVSampleBufferDisplayLayer()
    let recording: Recording
    let kind: Kind
    var isChase: Bool { kind == .chase }
    private(set) var phase: Phase = .idle
    private(set) var rendererState = RendererState()
    private(set) var duration: Double = 0
    /// 番組表の予定の長さ (追っかけのシークバーの全幅)
    private(set) var scheduledDuration: Double = 0
    private(set) var position: Double = 0
    private(set) var isPlaying = false
    private(set) var speed: Double = 1
    private(set) var qualityItems: [PlaybackRules.QualityItem] = []
    /// `nil` は「自動」(D18)
    private(set) var selectedQuality: OfferCodec?
    /// 選んだ解像度の段 (0 は元のまま)。その画面の間だけ
    private(set) var selectedRung = 0
    private(set) var currentCodec: OfferCodec?
    private(set) var audioTracks: [RecordingRules.AudioChoice] = []
    private(set) var selectedAudio: RecordingRules.AudioChoice?
    private(set) var hasCaptions = false
    private(set) var captionPage: CaptionPage?
    private(set) var captionsOn: Bool
    private(set) var chapters: [Chapter] = []
    private(set) var cmSkipEnabled: Bool
    private(set) var showReconnect = false
    private(set) var stop: Stop?
    private(set) var finished = false
    /// 端末が PiP に対応していれば作る (#48)。`nil` ならボタンを出さない
    private(set) var pictureInPicture: PictureInPicture?
    private(set) var pictureInPictureActive = false

    private let baseURL: URL
    private var token: String?
    private var playable: [OfferCodec]
    /// 追っかけの画質のメニューに使う (api/playback/options の liveCodecs)
    private var liveCodecs: [OfferCodec] = []
    private let defaults: UserDefaults
    private let nowPlaying: NowPlayingController
    private let nowPlayingID = UUID()
    private weak var app: AppModel?
    /// 「最初から」で開くときの位置 (秒)。`nil` なら `resumeMs` から
    private let startFrom: Double?
    private var policy: RecordingPlaybackPolicy
    private var playback: Playback?
    private var offer: Offer?
    private var renderer: MediaRenderer?
    private var loader: StreamLoader?
    private var chaptersSubscription: AppModel.Subscription?
    private var initialChaptersTask: Task<Void, Never>?
    private var chaptersRequestID = 0
    private var hasLoadedChapters = false
    private var captionPages: [RecordingCaptionPage] = []
    private var captionCursor = 0
    private var captionTimeline = CaptionTimeline()
    private var captionsRequested = false
    private var connectionTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    /// 閉じたあと・開き直したあとに届いた古いコールバックを捨てる印
    private(set) var generation = 0
    private var closed = false
    private(set) var inBackground = false
    private(set) var videoEpoch = 0
    private var firstFrameSeen = false
    private var drainingRecordingEnd = false
    private var lastCmSkipDestination: Double?
    private var handledDecodeFailure = false
    private var bufferedSince: Date?
    private var lastPosition = 0.0
    private var lastProgressAt = Date()
    private var lastResumeSent = Date.distantPast
    /// 開いているストリームの時刻が 0 になる位置。PiP の窓の範囲をレイヤの時計に合わせるのに使う (#48)
    private var pictureInPictureAnchor: Double = 0
    /// 映像の穴を埋める開き直しをしたか。1 つの穴につき 1 回だけにする (#48)
    private var reopenedForVideoGap = false
    private var pendingPause = false
    private var streamClosed = false
    private var pendingSeekOnReturn = false
    private var pausedOnReturn = false
    /// 追っかけの 404 (まだ何も録れていない) の回数
    private var chase404Count = 0
    /// これまでで一番先まで見た録れている所。シークで戻っても縮めない
    private var peakRecordedThrough: Double = 0
    /// 状態 (`GET api/recordings/<id>`) から読んだ実長。予定の長さとは分ける
    private(set) var statusDurationMs: Int64?
    /// 録画の先頭の放送時刻 (`jikkyo.head`)。世帯の設定がオフなら nil
    private var jikkyoHeadMs: Int64?
    /// いま開いているストリームの URL (テストで `from=` などを確かめる)
    var currentStreamURL: URL? { loader?.url }
    private let startStream: (StreamLoader) -> Void
    private let waitForChapterRetry: (Duration) async -> Void
    /// いまアプリが裏か。テストから差し替える (シミュレータのホストの状態で成否が変わらないように)
    private let appIsBackground: @MainActor () -> Bool
    private var chaseCloseTask: Task<Void, Never>?
    /// いまのストリームの段。続けられる今の接続 (再生中・一時停止中) があれば、選んだ段 (`selectedRung`) を試し、
    /// 採用したとき (200・再生できる形式・初期化と最初の映像の標本) にここへ移す。切り替えは試しを始めた位置から。
    /// 無いとき (開いている途中・止まった画面) は、選んだその場でここへ移す
    private var committedRung = 0
    /// 段を試している接続と、その `from`。今のストリームは閉じずに続け、200 が返ってから切り替える
    /// (denpa の api.md「rung」: 混んでいて断られたら今のストリームをそのまま続ける)
    private var trialLoader: StreamLoader?
    private var trialFrom: Double = 0
    /// 同じ押下が 2 つの経路 (決定・再生/一時停止ボタンと Now Playing) から届いたかの控え
    private var press = PressGuard()

    init(
        baseURL: URL,
        token: String?,
        recording: Recording,
        playable: [OfferCodec],
        app: AppModel?,
        kind: Kind = .recording,
        startFrom: Double? = nil,
        defaults: UserDefaults = .standard,
        nowPlaying: NowPlayingController = .shared,
        startStream: @escaping (StreamLoader) -> Void = { $0.start() },
        waitForChapterRetry: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        clock: @escaping () -> DispatchTime = { .now() },
        appIsBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
    ) {
        self.baseURL = baseURL
        self.token = token
        self.recording = recording
        self.kind = kind
        self.scheduledDuration = Double(max(0, recording.endAt - recording.startAt)) / 1000
        self.playable = playable
        self.app = app
        self.startFrom = startFrom
        self.defaults = defaults
        self.nowPlaying = nowPlaying
        self.startStream = startStream
        self.waitForChapterRetry = waitForChapterRetry
        self.appIsBackground = appIsBackground
        self.policy = RecordingPlaybackPolicy(playable: playable)
        self.cmSkipEnabled = recording.cmReliable
        self.captionsOn = defaults.object(forKey: "captionsOn") as? Bool ?? true
        self.press.now = clock
    }

    // MARK: - 開く

    func start() async {
        guard phase == .idle else { return }
        phase = .loading
        closed = false
        lastCmSkipDestination = nil
        hasLoadedChapters = false
        generation += 1
        setUpRenderer()
        chaptersSubscription?.cancel()
        chaptersSubscription = nil
        if !isChase {
            // 追っかけはチャプターを使わない (バーにも CM 飛ばしにも出さない) ので購読しない
            chaptersSubscription = app?.addEventListener { [weak self] event in
                guard event.event == "chapters", let self, !self.closed else { return }
                // 通知は {"recordingId": 12}。観ている録画のものだけ読み直す
                guard
                    let data = event.data.data(using: .utf8),
                    let notice = try? JSONDecoder().decode(ChaptersNotice.self, from: data),
                    notice.recordingId == self.recording.id
                else { return }
                Task { await self.reloadChapters() }
            }
        }
        if kind == .chase {
            await startChase()
            return
        }
        do {
            guard let app else { throw AppModel.APIError.notConnected }
            let data = try await app.get("api/recordings/\(recording.id)/playback")
            guard !closed else { return }
            let playback = try JSONDecoder().decode(Playback.self, from: data)
            self.playback = playback
            captionsRequested = false
            captionPages = []
            hasCaptions = false
            if playback.video == false {
                finish(.noVideo, retry: false)
                return
            }
            duration = playback.duration
            audioTracks = playback.audios.map(RecordingRules.AudioChoice.init)
            selectedAudio = RecordingRules.pickAudioChoice(
                audioTracks,
                savedName: defaults.string(forKey: "recordingAudioName")
            )
            qualityItems = PlaybackRules.recordingQualityMenu(offers: playback.offers, playable: playable)
            selectedQuality = nil
            position = startFrom ?? RecordingRules.startPosition(resumeMs: recording.resumeMs)
            guard chooseOffer() else {
                finish(.noPlayableFormat, retry: false)
                return
            }
            Self.logger.info("recording open id=\(self.recording.id, privacy: .public) from=\(self.position, privacy: .public)")
            openStream(from: position)
            initialChaptersTask = Task { [weak self] in
                await self?.reloadChapters()
            }
        } catch {
            finish(.refused(Self.message(error)), retry: true)
        }
    }

    /// 追っかけ (3.3)。`playback` は無い。画質はその場でエンコードできるものから 1 つ (段 0 の選択肢では H.265 は外す。段 1〜3 ではサーバが H.265 を選ぶことがある)。
    private func startChase() async {
        chase404Count = 0
        guard let app else {
            finish(.refused(String(localized: "denpa に接続されていません")), retry: true)
            return
        }
        if let data = try? await app.get("api/playback/options"),
           let options = try? JSONDecoder().decode(PlaybackOptions.self, from: data) {
            guard !closed else { return }
            liveCodecs = options.liveCodecs
        }
        qualityItems = PlaybackRules.liveQualityMenu(liveCodecs: liveCodecs, playable: playable, chase: true)
        selectedQuality = nil
        captionsRequested = false
        captionPages = []
        hasCaptions = false
        audioTracks = recording.audios.map(RecordingRules.AudioChoice.init)
        selectedAudio = RecordingRules.pickAudioChoice(
            audioTracks,
            savedName: defaults.string(forKey: "recordingAudioName")
        )
        duration = scheduledDuration
        position = startFrom ?? RecordingRules.startPosition(resumeMs: recording.resumeMs)
        Self.logger.info("chase open id=\(self.recording.id, privacy: .public) from=\(self.position, privacy: .public)")
        await reloadStatus()
        guard !closed else { return }
        // 開いたときの見積り: 録画の先頭からの経過時間 (予定の長さで頭打ち)。
        // 途中から録った録画を番組の始まりから数えない (jikkyo.head が無ければ見積もらない)
        peakRecordedThrough = RecordingRules.elapsedThrough(
            headMs: jikkyoHeadMs,
            now: Date(),
            scheduled: scheduledDuration
        )
        openStream(from: position)
    }

    /// いま録れている所まで。これまでで一番先まで見た値と、この接続で分かる値の大きいほう
    var recordedThrough: Double {
        guard isChase else { return duration }
        let current = RecordingRules.recordedThrough(
            position: position,
            buffered: rendererState.buffered,
            scheduled: scheduledDuration
        )
        return max(peakRecordedThrough, current)
    }

    /// シークできる上限。追っかけは録れている所まで
    var seekLimit: Double {
        isChase ? max(position, recordedThrough) : duration
    }

    /// シークバーの全幅 (追っかけは番組の予定の長さ)
    var scrubDuration: Double {
        isChase ? max(scheduledDuration, recordedThrough) : duration
    }

    /// 「最新」。録れている所の少し手前へ
    func jumpToLatest() {
        guard isChase else { return }
        // 進むだけ。今より後ろへは戻さない。ほぼ同じ所なら開き直さない
        let target = RecordingRules.latestTarget(position: position, recordedThrough: recordedThrough)
        guard target > position + 0.5 else { return }
        seek(to: target)
    }

    func reloadStatus() async {
        guard let app else { return }
        do {
            let data = try await app.get("api/recordings/\(recording.id)")
            guard !closed else { return }
            let status = try JSONDecoder().decode(RecordingStatus.self, from: data)
            jikkyoHeadMs = status.jikkyo?.head
            if let ms = status.durationMs {
                statusDurationMs = ms
                duration = Double(ms) / 1000
                if scheduledDuration == 0 { scheduledDuration = duration }
            }
        } catch {
            Self.logger.info("recording status failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 裏に回ったとき (#32)。再生中は接続と音を保って映像の層だけ止め、
    /// 一時停止中など再生していないときは接続を閉じて位置を預ける。
    /// PiP の窓に出ている間は、止めていても閉じない (#48)
    func enterBackground() {
        guard !inBackground else { return }
        inBackground = true
        videoEpoch += 1
        UIApplication.shared.isIdleTimerDisabled = false
        if RecordingRules.shouldCloseOnBackground(phase: phase, pictureInPicture: pictureInPictureActive) {
            closeForBackground()
        } else {
            sendResume(at: position)
            applyVideoState()
        }
    }

    /// 裏で再生していないので接続を閉じ、位置を預ける (#32)。
    /// PiP の窓を閉じたときに裏の決まりを引き直すときにも走らせる (#48)
    private func closeForBackground() {
        guard phase == .paused || phase == .loading || phase == .reconnecting else { return }
        sendResume(at: position)
        pendingSeekOnReturn = true
        pausedOnReturn = phase == .paused || pendingPause
        cancelTrial()
        chaseCloseTask?.cancel()
        chaseCloseTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        applyVideoState()
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        isPlaying = false
        showReconnect = false
        phase = .paused
    }

    func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        videoEpoch += 1
        applyVideoState()
        if isPlaying {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        guard pendingSeekOnReturn else { return }
        pendingSeekOnReturn = false
        guard !finished, stop == nil else { return }
        pendingPause = pausedOnReturn
        pausedOnReturn = false
        openStream(from: position)
    }

    /// 先に映像と音を止め、観た位置の送信だけを短く待ってから閉じる。
    /// サーバが応答しなくても 2 秒で閉じる (一覧の読み直しは resume のあと)
    func close() async {
        guard !closed else { return }
        closed = true
        cancelTrial()
        generation += 1
        pictureInPicture?.stop()
        let last = position
        chaseCloseTask?.cancel()
        chaseCloseTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        chaptersSubscription?.cancel()
        chaptersSubscription = nil
        initialChaptersTask?.cancel()
        initialChaptersTask = nil
        chaptersRequestID += 1
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        UIApplication.shared.isIdleTimerDisabled = false
        showReconnect = false
        // 再生の画面を閉じたら、テレビのモードを元に戻す (3.3)
        DisplayMode.reset()
        await sendResumeNow(at: last, timeout: 2)
        if !finished, stop == nil {
            phase = .idle
        }
    }

    // MARK: - 操作

    @discardableResult
    func play() -> Bool {
        guard !closed, stop == nil, !finished else { return false }
        if !isPlaying {
            if phase == .loading {
                pendingPause = false
                publishNowPlaying(isPlaying: true)
                return true
            }
            togglePlay()
        }
        return true
    }

    @discardableResult
    func pause() -> Bool {
        guard !closed, stop == nil, !finished else { return false }
        if isPlaying {
            togglePlay()
        } else if phase == .loading {
            pendingPause = true
            publishNowPlaying(isPlaying: false)
            pictureInPicture?.invalidatePlaybackState()
        }
        return true
    }

    @discardableResult
    func togglePlayCommand() -> Bool {
        let shouldPause = isPlaying || (phase == .loading && !pendingPause)
        return setPlayingFromCommand(!shouldPause)
    }

    /// 決定・再生/一時停止ボタンと Now Playing の play/pause/toggle で押下の控えを共有する。
    private func setPlayingFromCommand(_ shouldPlay: Bool) -> Bool {
        guard !closed, stop == nil, !finished else { return false }
        // 捨てた押下も「扱った」として true を返す (Now Playing に noActionableNowPlayingItem を返さない)
        guard press.claim() else { return true }
        return shouldPlay ? play() : pause()
    }

    func togglePlay() {
        guard stop == nil, !finished else { return }
        if isPlaying {
            isPlaying = false
            phase = .paused
            renderer?.setRate(0)
            UIApplication.shared.isIdleTimerDisabled = false
            sendResume(at: position)
            publishNowPlaying(isPlaying: false)
            pictureInPicture?.invalidatePlaybackState()
        } else if streamClosed || loader == nil {
            // 一時停止の間にサーバが閉じていた。同じ位置から開き直して、そのまま再生する
            streamClosed = false
            pendingPause = false
            openStream(from: position)
            publishNowPlaying(isPlaying: true)
        } else {
            isPlaying = true
            phase = .playing
            renderer?.setRate(speed)
            UIApplication.shared.isIdleTimerDisabled = !inBackground
            lastProgressAt = Date()
            publishNowPlaying(isPlaying: true)
            pictureInPicture?.invalidatePlaybackState()
        }
    }

    func seek(to target: Double) {
        seek(to: target, skippingCommercial: false)
    }

    private func seek(to target: Double, skippingCommercial: Bool) {
        guard stop == nil, !finished else { return }
        let clamped = min(max(0, target), max(0, seekLimit))
        // 手動シークで同じ CM に戻ったときは、再び飛ばせるようにする。
        lastCmSkipDestination = skippingCommercial ? clamped : nil
        chaseCloseTask?.cancel()
        chaseCloseTask = nil
        let wasPlaying = isPlaying
        isPlaying = false
        // 最初のコマより前に動かしたときは、止めずにその位置から映す
        pendingPause = firstFrameSeen && !wasPlaying
        position = clamped
        Self.logger.info("\(self.isChase ? "chase" : "recording") seek to \(clamped, privacy: .public)")
        openStream(from: clamped)
        if nowPlaying.currentOwner == nowPlayingID {
            publishNowPlaying(isPlaying: !pendingPause)
        }
        pictureInPicture?.invalidatePlaybackState()
    }

    func skip(by delta: Double) {
        seek(to: RecordingRules.seek(position, by: delta, duration: seekLimit))
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        if isPlaying {
            renderer?.setRate(speed)
        }
        if nowPlaying.currentOwner == nowPlayingID {
            publishNowPlaying(isPlaying: isPlaying)
        }
    }

    func selectQuality(_ codec: OfferCodec?) {
        guard codec != selectedQuality else { return }
        selectedQuality = codec
        if !isChase {
            guard chooseOffer() else {
                finish(.noPlayableFormat, retry: true)
                return
            }
        }
        let wasPlaying = isPlaying
        isPlaying = false
        pendingPause = !wasPlaying
        openStream(from: position)
    }

    /// 音声だけの観方では空 (解像度の欄を出さない)
    var rungItems: [PlaybackRules.RungItem] { PlaybackRules.rungMenu(currentCodec: currentCodec) }

    /// 形式を選び直したときと同じく、いた位置からリクエストし直す
    /// 再生中・一時停止中は、今のストリームを続けたまま新しい段をいた位置から試す。
    /// 200 が返ったら、形式を選び直したときと同じく、いた位置から切り替える
    func selectRung(_ rung: Int) {
        guard PlaybackRules.isRung(rung), rung != selectedRung else { return }
        if trialLoader != nil, rung == committedRung {
            // 今流れている段に選び直した。試しを捨てるだけで、今の接続・再生の状態はそのまま
            cancelTrial()
            return
        }
        guard !closed, stop == nil, !finished, phase == .playing || phase == .paused,
              let url = streamURL(from: position, rung: rung) else {
            // 映しているストリームが無い (開いている途中・止まった)。試さずにそのまま選ぶ
            cancelTrial()
            selectedRung = rung
            committedRung = rung
            // 録画で playback を取る前 (offer が無い) は開き直さない。start() が committedRung で最初から開く
            if !closed, stop == nil, !finished, phase == .loading || phase == .reconnecting, isChase || offer != nil {
                openStream(from: position)
            }
            return
        }
        // 試している間に選び直したら、試している接続だけ捨てて新しいほうを試す
        trialLoader?.cancel()
        selectedRung = rung
        trialFrom = position
        let trial = makeLoader(url: url, holding: true)
        trialLoader = trial
        Self.logger.info("\(self.isChase ? "chase" : "recording") try rung=\(rung, privacy: .public) from=\(self.trialFrom, privacy: .public)")
        startStream(trial)
    }

    /// 試している接続を捨て、選択をいまのストリームの段に戻す
    private func cancelTrial() {
        trialLoader?.cancel()
        trialLoader = nil
        selectedRung = committedRung
    }

    /// 試した段が 200 を返し、再生できる形式で初期化と最初の映像の標本が届いた。ここで初めて今の接続を閉じて切り替える。
    /// 再生・一時停止の意図は切り替えるときの `isPlaying` から引き継ぐ (試している間は触らない)
    private func adoptTrial(_ trial: StreamLoader, codec: String?) {
        trialLoader = nil
        committedRung = selectedRung
        Self.logger.info("\(self.isChase ? "chase" : "recording") switch rung=\(self.committedRung, privacy: .public)")
        let wasPlaying = isPlaying
        isPlaying = false
        pendingPause = !wasPlaying
        attach(trial, from: trialFrom)
        // レンダラの reset のあとに溜めていた標本を渡す (どちらも media の列で順に走る)
        trial.release()
        handleResponse(codec: codec)
    }

    /// 試した段が断られた (混んでいる・失敗)。再試行せず、今のストリームを続ける
    private func rejectTrial(_ trial: StreamLoader, reason: String) {
        trial.cancel()
        trialLoader = nil
        Self.logger.info("\(self.isChase ? "chase" : "recording") rung=\(self.selectedRung, privacy: .public) refused (\(reason, privacy: .public)); keep rung=\(self.committedRung, privacy: .public)")
        selectedRung = committedRung
    }

    func selectAudio(_ track: RecordingRules.AudioChoice) {
        guard track.id != selectedAudio?.id else { return }
        selectedAudio = track
        if !track.label.isEmpty {
            defaults.set(track.label, forKey: "recordingAudioName")
        }
        let wasPlaying = isPlaying
        isPlaying = false
        pendingPause = !wasPlaying
        openStream(from: position)
    }

    func setCaptionsOn(_ on: Bool) {
        captionsOn = on
        defaults.set(on, forKey: "captionsOn")
        updateCaption()
    }

    func setCmSkip(_ on: Bool) {
        cmSkipEnabled = on
    }

    func retry() {
        guard stop != nil else { return }
        stop = nil
        finished = false
        if playback == nil {
            // `playback` を読むところで失敗した。最初からやり直す
            phase = .idle
            Task { await start() }
        } else {
            phase = .loading
            openStream(from: position)
        }
    }

    func captionHidden(_ run: CaptionRun) -> Bool {
        guard captionsOn else { return true }
        return captionTimeline.isHidden(run, at: position * 1000)
    }

    // MARK: - 開く・繋ぎ直す

    private func setUpRenderer() {
        guard renderer == nil else { return }
        let created = MediaRenderer(displayLayer: displayLayer) { [weak self] state in
            Task { @MainActor in self?.receive(state) }
        }
        created.setVideoEnabled(!inBackground, epoch: videoEpoch)
        renderer = created
        // 録画は長さと位置を返すので、窓にスキップを出す (#48)
        pictureInPicture = PictureInPicture(displayLayer: displayLayer, source: self, linear: false)
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

    private func publishNowPlaying(isPlaying: Bool) {
        guard !closed, stop == nil, !finished else { return }
        guard nowPlaying.currentOwner == nil || nowPlaying.currentOwner == nowPlayingID else { return }
        nowPlaying.update(
            owner: nowPlayingID,
            item: .recording(
                recording: recording,
                isPlaying: isPlaying,
                speed: speed,
                position: position,
                duration: scrubDuration
            ),
            onPlay: { [weak self] in self?.setPlayingFromCommand(true) ?? false },
            onPause: { [weak self] in self?.setPlayingFromCommand(false) ?? false },
            onToggle: { [weak self] in self?.togglePlayCommand() ?? false }
        )
    }

    private func chooseOffer() -> Bool {
        guard let playback else { return false }
        let chosen: Offer?
        if let selectedQuality {
            chosen = playback.offers.first {
                $0.way == .stream && $0.codec == selectedQuality && playable.contains($0.codec)
            }
        } else {
            chosen = PlaybackRules.selectRecordingOffer(
                offers: playback.offers,
                playable: playable,
                broadcast: playback.broadcast
            )
        }
        offer = chosen
        currentCodec = chosen?.codec
        return chosen != nil
    }

    /// 録画なら `stream`、追っかけなら `chase` の URL
    private func streamURL(from: Double, rung: Int) -> URL? {
        if isChase { return chaseURL(from: from, rung: rung) }
        return offer.flatMap { streamURL(from: from, offer: $0, rung: rung) }
    }

    private func streamURL(from: Double, offer: Offer, rung: Int) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appending(path: "api/recordings/\(recording.id)/stream"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = [
            URLQueryItem(name: "codec", value: offer.codec.rawValue),
            URLQueryItem(name: "from", value: String(format: "%.3f", max(0, from))),
        ]
        if let selectedAudio { items.append(URLQueryItem(name: "audio", value: selectedAudio.id)) }
        items += PlaybackRules.rungQueryItems(rung)
        // 段を下げるときのコーデックはサーバが playable から選ぶ。自動のときだけ渡す (省くと codec と h264)
        if rung != 0, selectedQuality == nil {
            items.append(URLQueryItem(name: "playable", value: playable.map(\.rawValue).joined(separator: ",")))
        }
        components.queryItems = items
        return components.url
    }

    /// 追っかけ。画質を選んだときは `codec=`、自動なら `codec=auto&playable=`
    private func chaseURL(from: Double, rung: Int) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appending(path: "api/recordings/\(recording.id)/chase"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items: [URLQueryItem] = []
        if let selectedQuality {
            items.append(URLQueryItem(name: "codec", value: selectedQuality.rawValue))
        } else {
            items.append(URLQueryItem(name: "codec", value: "auto"))
            items.append(URLQueryItem(name: "playable", value: playable.map(\.rawValue).joined(separator: ",")))
        }
        items.append(URLQueryItem(name: "from", value: String(format: "%.3f", max(0, from))))
        if let selectedAudio { items.append(URLQueryItem(name: "audio", value: selectedAudio.id)) }
        items += PlaybackRules.rungQueryItems(rung)
        components.queryItems = items
        return components.url
    }

    private func openStream(from: Double) {
        guard !closed, stop == nil else { return }
        cancelTrial()
        let url: URL
        if isChase {
            guard let chase = chaseURL(from: from, rung: committedRung) else {
                finish(.noPlayableFormat, retry: false)
                return
            }
            url = chase
        } else {
            guard let offer, let stream = streamURL(from: from, offer: offer, rung: committedRung) else {
                if offer == nil { finish(.noPlayableFormat, retry: false) }
                return
            }
            url = stream
        }
        let loader = makeLoader(url: url, holding: false)
        attach(loader, from: from)
        startStream(loader)
    }

    /// 前の接続を止めてレンダラを `from` から作り直し、`loader` をいまの接続にする
    private func attach(_ loader: StreamLoader, from: Double) {
        generation += 1
        chaseCloseTask?.cancel()
        chaseCloseTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        self.loader?.cancel()
        self.loader = nil
        showReconnect = false
        streamClosed = false
        stop = nil
        phase = .loading
        firstFrameSeen = false
        drainingRecordingEnd = false
        reopenedForVideoGap = false
        handledDecodeFailure = false
        bufferedSince = nil
        lastPosition = from
        lastProgressAt = Date()
        rendererState = RendererState()
        // 追っかけは開き直した位置からレイヤの時計が 0 で始まる。録画の stream は PTS がそのまま位置 (#48)
        pictureInPictureAnchor = isChase ? from : 0
        renderer?.reset(live: false, from: from, ruler: !isChase, generation: generation)
        rebuildCaptions()
        Self.logger.info("\(self.isChase ? "chase" : "recording") stream from=\(from, privacy: .public)")
        self.loader = loader
    }

    /// コールバックは、いまの接続 (`loader`) か試している接続 (`trialLoader`) のものだけを受ける。
    /// 閉じたあと・開き直したあとに届いた古いものは捨てる
    private func makeLoader(url: URL, holding: Bool) -> StreamLoader {
        let loader = StreamLoader(url: url, mode: .buffered, token: token, holding: holding) { [weak renderer] in
            renderer?.bufferedAhead ?? 0
        }
        // 試しの接続のヘッダは受けない。採用 (onReady) のときに 1 度だけ応答として扱う
        if !holding {
            loader.onResponse = { [weak self, weak loader] codec, _ in
                Task { @MainActor in
                    guard let self, let loader, loader === self.loader else { return }
                    self.handleResponse(codec: codec)
                }
            }
        }
        loader.onReady = { [weak self, weak loader] codec, _ in
            Task { @MainActor in
                guard let self, let loader, loader === self.trialLoader else { return }
                // 段を下げた応答はサーバが選んだコーデック。この端末で再生できるものだけ採用する
                if let parsed = codec.flatMap(OfferCodec.init(rawValue:)), self.playable.contains(parsed) {
                    self.adoptTrial(loader, codec: codec)
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

    private func handleResponse(codec: String?) {
        guard !closed, stop == nil, !finished else { return }
        if isChase || committedRung != 0 {
            // 段を下げた録画は、サーバが選んだコーデックで来る
            currentCodec = codec.flatMap(OfferCodec.init(rawValue:)) ?? offer?.codec
        } else {
            currentCodec = offer?.codec
        }
    }

    /// テストからも呼ぶ (閉じたあとの遅れたコールバックで再開しないこと)
    func handleFailure(_ failure: StreamFailure) {
        guard !closed, stop == nil, !finished else { return }
        if failure.status == 401 {
            switch failure.errorCode {
            case "invalid_token":
                app?.discardToken(for: baseURL)
                token = nil
                openStream(from: position)
            default:
                app?.requirePairing(for: baseURL)
                finish(.refused(failure.message ?? String(localized: "認証が必要です")), retry: false)
            }
            return
        }
        if isChase, failure.status == 404 {
            // 録り始めたばかりで何も録れていないことがある。2 秒おきに 3 回まで (3.3)
            chase404Count += 1
            if chase404Count <= 3 {
                scheduleReopen(from: position, after: 2)
            } else {
                finish(.refused(failure.message ?? String(localized: "まだ録画データがありません")), retry: true)
            }
            return
        }
        if phase == .paused || pendingPause {
            // 一時停止して 5 分たつとサーバが変換を止める。再開したときに開き直す
            streamClosed = true
            return
        }
        let actions = policy.handle(
            .failed(status: failure.status, message: failure.message, errorCode: failure.errorCode),
            position: position,
            duration: duration
        )
        apply(actions)
    }

    func handleFinish(empty: Bool) {
        guard !closed, stop == nil, !finished else { return }
        if isChase {
            if phase == .paused || pendingPause {
                streamClosed = true
                return
            }
            chaseCloseTask?.cancel()
            if empty {
                // 200 のまま中身が空。3 回まで開き直し、だめなら止める (3.3)
                apply(policy.handle(.empty, position: position, duration: duration))
                return
            }
            chaseCloseTask = Task { [weak self] in
                await self?.handleChaseClosed()
            }
            return
        }
        if phase == .paused || pendingPause {
            // 一時停止して 5 分たつとサーバが変換を止める。再開したときに開き直す
            streamClosed = true
            return
        }
        let actions = empty
            ? policy.handle(.empty, position: position, duration: duration)
            : policy.handle(.closed, position: position, duration: duration)
        if actions == [.end] {
            // HTTP の終端が、バッファの再生や最初のコマの通知より先に届くことがある。
            drainingRecordingEnd = true
            renderer?.drainRecordingEnd(generation: generation)
            return
        }
        apply(actions)
    }

    /// 追っかけが閉じた (番組が替わった・録り終えた)。届いたぶんを観てから状態を見る (3.3)
    private func handleChaseClosed() async {
        // 溜まっているぶん (受け取った先と、録れている所) を観終わるまで待つ。
        // 2 倍なら半分の時間で着く
        let ahead = min(rendererState.buffered, max(0, recordedThrough - position))
        let seconds = speed > 1 ? ahead / speed : ahead
        let wait = min(30, seconds)
        if wait > 0.1 {
            try? await Task.sleep(for: .seconds(wait))
        }
        guard !Task.isCancelled, !closed, stop == nil, !finished else { return }
        // 待っている間に一時停止したなら、開き直さず再開を待つ
        if phase == .paused || pendingPause {
            streamClosed = true
            return
        }
        await reloadStatus()
        guard !Task.isCancelled, !closed, stop == nil, !finished else { return }
        // 予定の長さではなく、状態から読んだ実長だけで終わりを決める
        if RecordingRules.chaseFinished(position: position, durationMs: statusDurationMs) {
            finishPlayback()
            return
        }
        apply(policy.handle(.closed, position: position, duration: duration))
    }

    private func apply(_ actions: [RecordingAction]) {
        for action in actions {
            switch action {
            case .end:
                finishPlayback()
            case .reopen(let from, let after):
                scheduleReopen(from: max(from, position), after: after)
            case .removeCodec(let codec):
                cancelTrial()
                playable.removeAll { $0 == codec }
                // 選んでいた形式を外したら「自動」に戻す (D18)
                if let selectedQuality, !playable.contains(selectedQuality) {
                    self.selectedQuality = nil
                }
                rebuildQualityMenu()
                if !isChase { _ = chooseOffer() }
            case .stop(let reason, let retry):
                finish(reason, retry: retry)
            }
        }
    }

    private func scheduleReopen(from: Double, after seconds: Double) {
        // 今の接続が切れて開き直す。古い条件で作った試しは採用しない
        cancelTrial()
        connectionTask?.cancel()
        overlayTask?.cancel()
        showReconnect = false
        phase = .reconnecting
        let scheduled = generation
        connectionTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, let self, !self.closed, self.generation == scheduled else { return }
            self.connectionTask = nil
            self.openStream(from: from)
        }
        overlayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.firstFrameSeen else { return }
            self.showReconnect = true
        }
    }

    private func finish(_ reason: RecordingStopReason, retry: Bool) {
        guard !closed else { return }
        cancelTrial()
        stop = Stop(reason: reason, retry: retry)
        phase = .stopped
        isPlaying = false
        showReconnect = false
        pictureInPicture?.stop()
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        UIApplication.shared.isIdleTimerDisabled = false
        DisplayMode.reset()
        Self.logger.info("\(self.isChase ? "chase" : "recording") stop \(String(describing: reason), privacy: .public)")
    }

    private func finishPlayback() {
        guard !finished else { return }
        cancelTrial()
        finished = true
        phase = .ended
        isPlaying = false
        showReconnect = false
        pictureInPicture?.stop()
        connectionTask?.cancel()
        connectionTask = nil
        overlayTask?.cancel()
        overlayTask = nil
        loader?.cancel()
        loader = nil
        renderer?.stop()
        nowPlaying.clear(owner: nowPlayingID)
        captionPage = nil
        UIApplication.shared.isIdleTimerDisabled = false
        DisplayMode.reset()
        sendResume(at: max(position, duration))
        Self.logger.info("\(self.isChase ? "chase" : "recording") ended id=\(self.recording.id, privacy: .public)")
    }

    // MARK: - レンダラの状態

    /// テストからも呼ぶ (閉じたあとの遅れた状態で「観た」を送らないこと)
    func receive(_ state: RendererState) {
        guard !closed, stop == nil, !finished, state.generation == generation else { return }
        rendererState = state
        let now = Date()
        // 映像の形式が決まったら、テレビのモードを映像に合わせる (3.3・Apple TV)
        DisplayMode.apply(format: state.format, frameRate: state.frameRate)

        if state.isPlaying, !firstFrameSeen {
            firstFrameSeen = true
            showReconnect = false
            reopenedForVideoGap = false
            overlayTask?.cancel()
            overlayTask = nil
            // 映ったのだから、待っていた再開は要らない
            connectionTask?.cancel()
            connectionTask = nil
            policy.firstFrame(at: state.position)
            chase404Count = 0
            lastProgressAt = now
            if pendingPause {
                pendingPause = false
                isPlaying = false
                phase = .paused
                renderer?.setRate(0)
                UIApplication.shared.isIdleTimerDisabled = false
                pictureInPicture?.invalidatePlaybackState()
            } else {
                isPlaying = true
                phase = .playing
                if speed != 1 { renderer?.setRate(speed) }
                UIApplication.shared.isIdleTimerDisabled = !inBackground
            }
            position = state.position
            publishNowPlaying(isPlaying: isPlaying)
            if !isChase { fetchCaptions() }
        }

        if state.isPlaying {
            position = state.position
        }

        if isChase {
            let current = RecordingRules.recordedThrough(
                position: position,
                buffered: state.buffered,
                scheduled: scheduledDuration
            )
            peakRecordedThrough = max(peakRecordedThrough, current)
            // 2 倍で録れている所の 3 秒手前まで追いついたら 1 倍に戻す (3.5.3)
            if isPlaying, speed > 1,
               RecordingRules.caughtUp(position: position, recordedThrough: recordedThrough) {
                setSpeed(1)
                Self.logger.info("chase caught up: speed back to 1")
            }
        }

        if isPlaying, abs(position - lastPosition) >= 0.1 {
            lastPosition = position
            lastProgressAt = now
        }

        // 追っかけは録れている所が伸びるので、終わりはサーバが閉じたときに見る
        let recordingEnded = drainingRecordingEnd
            ? state.recordingEndDrained && (isPlaying || (!firstFrameSeen && !pendingPause))
            : RecordingRules.isFinished(position: position, duration: duration)
        if !isChase, recordingEnded {
            finishPlayback()
            return
        }

        // 先読み済みの録画・追っかけで短く裏へ回ると控えに now 以前のキーフレームが無く、
        // そのままでは 20〜30 秒間映像が出ないため、いまの位置から開き直す (#32)。
        // 裏でも PiP の窓に出ているなら同じことが要る (#48)
        if state.videoGap, state.videoEpoch == videoEpoch,
           RecordingRules.shouldReopenForVideoGap(
               inBackground: inBackground,
               pictureInPicture: pictureInPictureActive,
               alreadyReopened: reopenedForVideoGap
           ) {
            Self.logger.info("reopen for video gap pip=\(self.pictureInPictureActive, privacy: .public)")
            let wasPlaying = isPlaying
            isPlaying = false
            pendingPause = !wasPlaying
            openStream(from: position)
            // openStream は印を戻すので、この穴のぶんはここで立て直す (穴 1 回につき 1 回)
            reopenedForVideoGap = true
            return
        }

        if isPlaying, now.timeIntervalSince(lastProgressAt) >= 10 {
            lastProgressAt = now
            apply(policy.handle(.stalled, position: position, duration: duration))
            return
        }

        if !firstFrameSeen, now.timeIntervalSince(lastProgressAt) >= 15 {
            lastProgressAt = now
            apply(policy.handle(.stalled, position: position, duration: duration))
            return
        }

        // 裏へ回る境目や表へ戻す前の世代で作られた videoFailed は、対応形式の不備ではないので無視する
        if state.videoFailed,
           !inBackground,
           state.videoEpoch == videoEpoch,
           !appIsBackground(),
           !handledDecodeFailure {
            handledDecodeFailure = true
            if let codec = currentCodec ?? offer?.codec {
                apply(policy.handle(.decodeFailed(codec: codec), position: position, duration: duration))
            } else {
                apply(policy.handle(.stalled, position: position, duration: duration))
            }
            return
        }

        if !isChase, isPlaying, state.isPlaying, cmSkipEnabled,
           let destination = PlaybackRules.cmSkipDestination(
               chapters: chapters, position: position, lastSkippedEnd: lastCmSkipDestination
           ),
           destination - position > 0.5, destination < duration - 0.3 {
            seek(to: destination, skippingCommercial: true)
            return
        }

        if isPlaying, now.timeIntervalSince(lastResumeSent) >= 15 {
            lastResumeSent = now
            sendResume(at: position)
        }

        updateCaption()
    }

    // MARK: - 字幕

    private func fetchCaptions() {
        guard !DemoServer.isDemo(baseURL) else { return }
        guard !captionsRequested else { return }
        captionsRequested = true
        Task { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: self.baseURL.appending(path: "api/recordings/\(self.recording.id)/captions.json"))
            request.timeoutInterval = 60
            if let token = self.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    Self.logger.info("recording captions status=\(status, privacy: .public)")
                    return
                }
                guard
                    let captions = try? JSONDecoder().decode(RecordingCaptions.self, from: data),
                    captions.v == 1,
                    !captions.pages.isEmpty
                else {
                    Self.logger.info("recording captions decode failed")
                    return
                }
                self.captionPages = captions.pages.sorted { $0.at < $1.at }
                self.hasCaptions = true
                self.rebuildCaptions()
                Self.logger.info("recording captions pages=\(self.captionPages.count, privacy: .public)")
            } catch {
                Self.logger.info("recording captions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rebuildCaptions() {
        captionTimeline = CaptionTimeline.rebuilt(from: captionPages, position: position)
        captionCursor = captionPages.firstIndex(where: { $0.at > position + 0.001 }) ?? captionPages.count
        updateCaption()
    }

    private func updateCaption() {
        guard captionsOn else {
            captionPage = nil
            return
        }
        while captionCursor < captionPages.count, captionPages[captionCursor].at <= position + 0.001 {
            let entry = captionPages[captionCursor]
            captionTimeline.show(entry.page, at: entry.at * 1000)
            captionCursor += 1
        }
        captionPage = captionTimeline.page(at: position * 1000)
    }

    // MARK: - 観た位置

    private func sendResume(at seconds: Double) {
        Task { [weak self] in
            await self?.sendResumeNow(at: seconds)
        }
    }

    private func sendResumeNow(at seconds: Double, timeout: TimeInterval? = nil) async {
        guard let app, firstFrameSeen else { return }
        let body: RecordingRules.ResumeBody
        if isChase {
            // 追っかけの物差しは元の TS。長さは分かっていれば実長、まだなら予定 (3.3)
            let length = statusDurationMs.map { Double($0) / 1000 } ?? scheduledDuration
            body = RecordingRules.ResumeBody(
                at: max(0, seconds),
                length: max(0, length),
                source: "ts"
            )
        } else {
            guard let playback else { return }
            body = RecordingRules.resumeBody(at: seconds, duration: duration, axis: playback.axis)
        }
        guard let json = try? JSONEncoder().encode(body) else { return }
        let send = Task { @MainActor in
            _ = try? await app.post("api/recordings/\(self.recording.id)/resume", json: json)
        }
        if let timeout {
            let stopper = Task {
                try? await Task.sleep(for: .seconds(timeout))
                send.cancel()
            }
            await send.value
            stopper.cancel()
        } else {
            await send.value
        }
    }

    // MARK: - チャプター

    func reloadChapters() async {
        guard let app, !closed else { return }
        chaptersRequestID += 1
        let requestID = chaptersRequestID
        let delays = hasLoadedChapters ? [0] : [0, 1, 2, 4]
        for delay in delays {
            if delay > 0 {
                await waitForChapterRetry(.seconds(delay))
            }
            guard !closed, !Task.isCancelled, requestID == chaptersRequestID else { return }
            do {
                let data = try await app.get("api/recordings/\(recording.id)/chapters")
                guard !closed, !Task.isCancelled, requestID == chaptersRequestID else { return }
                chapters = try JSONDecoder().decode(Chapters.self, from: data).chapters
                hasLoadedChapters = true
                return
            } catch {
                Self.logger.info("recording chapters failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - その他

    private func rebuildQualityMenu() {
        if isChase {
            qualityItems = PlaybackRules.liveQualityMenu(liveCodecs: liveCodecs, playable: playable, chase: true)
            return
        }
        guard let playback else { return }
        qualityItems = PlaybackRules.recordingQualityMenu(offers: playback.offers, playable: playable)
    }

    /// SSE の `chapters` の本文
    private struct ChaptersNotice: Decodable {
        var recordingId: Int64
    }

    private static func message(_ error: any Error) -> String {
        switch error {
        case AppModel.APIError.http(_, let message):
            return message ?? String(localized: "再生できません")
        case AppModel.APIError.notConnected:
            return String(localized: "denpa に接続されていません")
        case AppModel.APIError.needsPairing:
            return String(localized: "認証が必要です")
        case AppModel.APIError.network(let message):
            return message
        default:
            return String(localized: "再生できません")
        }
    }
}

// MARK: - ピクチャ・イン・ピクチャ (#48)

extension RecordingSession: PictureInPicture.Source {
    var isPictureInPicturePaused: Bool { RecordingRules.pictureInPictureIsPaused(phase: phase) }

    /// 観られる範囲はシークできる上限まで (追っかけはまだ録れていない所を出さない)。
    /// 窓の時計はレイヤの時刻なので、開き直した位置を 0 として数える
    var pictureInPictureTimeRange: CMTimeRange {
        RecordingRules.pictureInPictureTimeRange(limit: seekLimit, anchor: pictureInPictureAnchor)
    }

    func setPictureInPicturePlaying(_ playing: Bool) {
        if playing {
            _ = play()
        } else {
            _ = pause()
        }
    }

    func skipPictureInPicture(by seconds: Double) {
        skip(by: seconds)
    }

    func pictureInPictureDidChange(_ active: Bool) {
        pictureInPictureActive = active
        guard inBackground else { return }
        // 裏にいる間に窓が開いた・閉じたときは、映像の止め方が変わる
        videoEpoch += 1
        applyVideoState()
        // 窓を閉じたら #32 の裏の決まりを引き直す (止めていたなら接続を閉じる)。開いたときは窓に出し続けるので閉じない
        if !active, RecordingRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: phase) {
            closeForBackground()
        }
    }
}
