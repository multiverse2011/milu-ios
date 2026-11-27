import Foundation
import Testing
@testable import Milu

@Suite @MainActor struct PlaybackSessionTests {
    private func makeDefaults() -> UserDefaults {
        let name = "PlaybackSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeSession(
        nowPlaying: NowPlayingController = NowPlayingController(backend: SpyNowPlayingBackend()),
        defaults: UserDefaults? = nil,
        playable: [OfferCodec] = Playable.formats,
        startLoader: ((StreamLoader) -> Void)? = nil,
        clock: @escaping () -> Date = { Date() }
    ) -> PlaybackSession {
        let defaults = defaults ?? makeDefaults()
        return PlaybackSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            defaults: defaults,
            nowPlaying: nowPlaying,
            onInvalidToken: { _ in },
            onNeedsPairing: { _ in },
            playable: playable,
            clock: clock,
            startLoader: startLoader ?? { $0.start() }
        )
    }

    private func makeService(
        programTitle: String = "ニュース",
        audios: [AudioTrack] = []
    ) -> Service {
        Service(
            id: 101,
            type: .GR,
            name: "NHK総合",
            remoteControlKey: 1,
            logo: nil,
            live: "/api/services/101/live",
            airing: true,
            video: true,
            now: CurrentProgram(
                id: 1,
                title: programTitle,
                startAt: 0,
                endAt: 1_800_000,
                reserved: false,
                recording: false,
                audios: audios
            )
        )
    }

    @Test func receiveDropsStateFromAnotherGeneration() {
        let session = makeSession()
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 10,
            timeline: 10,
            buffered: 0,
            message: nil,
            videoFailed: false,
            generation: 99
        ))
        #expect(session.phase == .idle)
    }

    @Test func closeThenFailureDoesNotRestart() {
        let session = makeSession()
        session.close()
        session.handleFailure(StreamFailure(status: nil, message: "切れました", errorCode: nil))
        #expect(session.phase == .idle)
        #expect(session.stop == nil)
    }

    @Test func nowPlayingUpdatesAndRemoteCommandsPauseAndResumeLive() {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let clock = Box(Date())
        let session = makeSession(nowPlaying: nowPlaying, clock: { clock.value })

        session.open(makeService(programTitle: "朝ドラ"), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        #expect(session.phase == .playing)
        #expect(backend.info?.title == "朝ドラ")
        #expect(backend.info?.station == "NHK総合")
        #expect(backend.info?.rate == 1)

        // ロック画面の一時停止で止め、Now Playing は残して再生に戻せる
        #expect(nowPlaying.handlePause())
        #expect(session.phase == .paused)
        #expect(backend.info?.rate == 0)

        // 一時停止中に番組が替わっても勝手に再開せず、題だけ更新する
        session.updateService(makeService(programTitle: "あさイチ"))
        #expect(session.phase == .paused)
        #expect(backend.info?.title == "あさイチ")

        // 押し直しは同じ押下ではない。時計を進めて間をあける
        clock.value = clock.value.addingTimeInterval(1)
        #expect(nowPlaying.handlePlay())
        #expect(session.phase == .loading)
        #expect(backend.info?.rate == 1)

        session.close()
        #expect(backend.info == nil)
        #expect(!backend.commandsEnabled)
    }

    /// 同じ押下が Now Playing の pause で先に届き、続けて決定 (toggle) で来ても動かない
    @Test func pauseCommandThenSelectIsTheSamePress() {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let clock = Box(Date())
        let session = makeSession(nowPlaying: nowPlaying, clock: { clock.value })
        session.open(makeService(), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        #expect(session.phase == .playing)

        // 押下は Now Playing の pause で先に届く
        #expect(nowPlaying.handlePause())
        #expect(session.phase == .paused)

        // 同じ押下が決定として届いても、止まったまま
        clock.value = clock.value.addingTimeInterval(0.1)
        #expect(session.togglePlayPause())
        #expect(session.phase == .paused)
    }

    /// 決定・再生/一時停止ボタンと Now Playing の toggle。同じ押下が 2 度届いても 1 度だけ動き、
    /// 間をあけた押下は選局し直してその時点のライブへ戻る (D17)
    @Test func togglePlayPauseIgnoresTheSamePressTwice() {
        let clock = Box(Date())
        let session = makeSession(clock: { clock.value })
        session.open(makeService(), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        #expect(session.phase == .playing)

        #expect(session.togglePlayPause())
        #expect(session.phase == .paused)

        // 同じ押下がもう 1 つの経路から届いても、止まったまま。
        // 捨てた押下も「扱った」として true を返す (Now Playing に失敗を返さない)
        clock.value = clock.value.addingTimeInterval(0.1)
        #expect(session.togglePlayPause())
        #expect(session.phase == .paused)

        // 間をあけた押下で再開する (接続を開き直すので .loading から)
        clock.value = clock.value.addingTimeInterval(1)
        #expect(session.togglePlayPause())
        #expect(session.phase == .loading)

        // 閉じたあとは動かさない
        session.close()
        clock.value = clock.value.addingTimeInterval(1)
        #expect(!session.togglePlayPause())
        #expect(session.phase == .idle)
    }

    @Test func videoFailureInBackgroundDoesNotStopPlayback() {
        let session = makeSession()
        session.open(makeService(), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 2,
            timeline: 2,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        session.setBackground(true)
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 3,
            timeline: 3,
            buffered: 1,
            message: "background gpu denied",
            videoFailed: true,
            generation: session.generation
        ))
        #expect(session.phase == .playing)
        #expect(session.stop == nil)
        session.close()
    }

    @Test func updateServiceAfterStopOrCloseDoesNotRestartAndKeepsNowPlayingEmpty() {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let session = makeSession(nowPlaying: nowPlaying)
        let mainAudio = AudioTrack(id: "0:main", stream: 0, side: "main", label: "主音声", main: true)
        let subAudio = AudioTrack(id: "0:sub", stream: 0, side: "sub", label: "副音声", main: false)

        session.open(makeService(programTitle: "番組A", audios: [mainAudio]), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        #expect(backend.info?.title == "番組A")

        // エラーで停止 (.stopped) したあとに updateService が来ても再開も publish もしない
        session.handleFailure(StreamFailure(status: 404, message: "ありません", errorCode: nil))
        #expect(session.phase == .stopped)
        #expect(backend.info == nil)

        session.updateService(makeService(programTitle: "番組A2", audios: [mainAudio]))
        #expect(session.phase == .stopped)
        #expect(backend.info == nil)

        session.updateService(makeService(programTitle: "番組B", audios: [subAudio]))
        #expect(session.phase == .stopped)
        #expect(session.stop != nil)
        #expect(backend.info == nil)

        // close (.idle) のあとに updateService が来ても再開も publish もしない
        session.close()
        session.updateService(makeService(programTitle: "番組C", audios: [mainAudio]))
        #expect(session.phase == .idle)
        #expect(backend.info == nil)
    }

    @Test func selectingQualityOrAudioWhilePausedDoesNotStartPlayback() {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let session = makeSession(nowPlaying: nowPlaying)
        let mainAudio = AudioTrack(id: "0:main", stream: 0, side: "main", label: "主音声", main: true)
        let subAudio = AudioTrack(id: "0:sub", stream: 0, side: "sub", label: "副音声", main: false)

        session.open(makeService(audios: [mainAudio, subAudio]), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        session.pause()
        #expect(session.phase == .paused)

        session.selectQuality(.h264)
        #expect(session.phase == .paused)
        #expect(session.selectedQuality == .h264)

        session.selectAudio(subAudio)
        #expect(session.phase == .paused)
        #expect(session.selectedAudio?.id == "0:sub")
        #expect(backend.info?.rate == 0)

        session.close()
    }

    @Test func doesNotStealNowPlayingFromAnotherOwnerOnFirstFrameOrPause() {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let otherOwner = UUID()
        let otherService = Service(
            id: 202, type: .BS, name: "BS1", remoteControlKey: nil, logo: nil,
            live: "/api/services/202/live", airing: true, video: true,
            now: CurrentProgram(id: 9, title: "別の再生", startAt: 0, endAt: 1000, reserved: false, recording: false, audios: [])
        )
        nowPlaying.update(
            owner: otherOwner,
            item: .live(service: otherService, isPlaying: true),
            onPlay: { true },
            onPause: { true },
            onToggle: { true }
        )

        let session = makeSession(nowPlaying: nowPlaying)
        session.open(makeService(programTitle: "横取りしない"), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        #expect(nowPlaying.currentOwner == otherOwner)
        #expect(backend.info?.title == "別の再生")

        session.pause()
        #expect(nowPlaying.currentOwner == otherOwner)
        #expect(backend.info?.title == "別の再生")
        #expect(backend.info?.rate == 1)

        session.close()
    }

    @Test func lateVideoFailureFromBeforeForegroundReturnIsIgnored() {
        let session = makeSession()
        session.open(makeService(), liveCodecs: [.h264])
        session.selectQuality(.h264)
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 2,
            timeline: 2,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation
        ))
        // 裏へ回る境目で作られた古い状態 (videoEpoch == 0) が、表へ戻ったあとに遅れて届く
        session.setBackground(true)
        session.setBackground(false)
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 2.5,
            timeline: 2.5,
            buffered: 1,
            message: "stale background gpu error",
            videoFailed: true,
            generation: session.generation
        ))
        #expect(session.phase == .playing)
        #expect(session.stop == nil)
        session.close()
    }

    @Test func currentEpochVideoFailureIsHandledAsFailure() {
        let session = makeSession()
        session.open(makeService(), liveCodecs: [.h264])
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 2,
            timeline: 2,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: session.generation,
            videoEpoch: session.videoEpoch
        ))
        session.setBackground(true)
        session.setBackground(false)
        // いまの世代 (videoEpoch == session.videoEpoch) の videoFailed は従来どおり繋ぎ直しへ回す
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 3,
            timeline: 3,
            buffered: 1,
            message: "decode failed",
            videoFailed: true,
            generation: session.generation,
            videoEpoch: session.videoEpoch
        ))
        #expect(session.phase == .reconnecting)
        session.close()
    }

    // MARK: 解像度 (段)

    /// 開いた接続を実際には繋がずに控える
    private final class Loaders {
        var all: [StreamLoader] = []
        var last: StreamLoader { all[all.count - 1] }
    }

    private func rungParam(_ url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "rung" }?.value
    }

    private func showFirstFrame(_ session: PlaybackSession) {
        session.receive(RendererState(
            isPlaying: true, codec: "avc1", position: 1, timeline: 1, buffered: 1,
            message: nil, videoFailed: false, generation: session.generation
        ))
    }

    /// ライブを開き、今の接続が 200 を受けて映ったところまで進める
    private func playingSession(
        defaults: UserDefaults,
        clock: @escaping () -> Date = { Date() }
    ) async -> (PlaybackSession, Loaders) {
        let loaders = Loaders()
        let session = makeSession(defaults: defaults, startLoader: { loaders.all.append($0) }, clock: clock)
        session.open(makeService(), liveCodecs: [.h264])
        injectResponse(into: loaders.last)
        await waitUntil { session.currentCodec == .h264 }
        showFirstFrame(session)
        return (session, loaders)
    }

    /// 今の接続が渡した標本の数を数える (数えたあとは今までどおりレンダラへ渡す)
    private func countSamples(of loader: StreamLoader) -> Box<Int> {
        let count = Box(0)
        let original = loader.onSamples
        loader.onSamples = { samples in
            count.value += 1
            original?(samples)
        }
        return count
    }

    private let busy = StreamFailure(status: 503, message: "サーバが混んでいます", errorCode: nil)

    @Test func liveRungIsTriedWithoutClosingAndKeptWhenBusy() async throws {
        let defaults = makeDefaults()
        let fixture = try streamFixture()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        let delivered = countSamples(of: current)
        let generation = session.generation
        #expect(rungParam(current.url) == nil)

        session.selectRung(2)
        let trial = loaders.last
        #expect(trial !== current)
        #expect(trial.url.path == "/api/services/101/live")
        #expect(rungParam(trial.url) == "2")
        // 試している間も今の接続は閉じず、標本を渡し続ける
        #expect(session.currentStreamURL == current.url)
        #expect(session.phase == .playing)
        #expect(!current.isCancelled)
        injectData(fixture, into: current)
        #expect(delivered.value > 0)

        trial.onFailure?(busy)
        await waitUntil { session.selectedRung == 0 }
        #expect(session.currentStreamURL == current.url)
        #expect(session.generation == generation)
        #expect(session.phase == .playing)
        #expect(session.stop == nil)
        #expect(defaults.object(forKey: "liveRung") == nil)
        // 再試行しない。断られたあとも今の接続は標本を渡す
        #expect(loaders.all.count == 2)
        #expect(!current.isCancelled)
        let before = delivered.value
        injectData(fixture, into: current)
        #expect(delivered.value > before)
        session.close()
    }

    @Test func liveRungSwitchesWhenReadyAndIsSavedThen() async {
        let defaults = makeDefaults()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        let generation = session.generation
        session.selectRung(1)
        let trial = loaders.last
        // 試しの接続のヘッダは受けない (採用のときに 1 度だけ応答として扱う)
        #expect(trial.onResponse == nil)
        #expect(current.onResponse != nil)
        // ヘッダの 200 だけでは採用しない
        trial.onResponse?("h264", "1")
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(defaults.object(forKey: "liveRung") == nil)

        trial.onReady?("h264", "1")
        await waitUntil { session.currentStreamURL == trial.url }
        #expect(rungParam(session.currentStreamURL) == "1")
        #expect(session.generation > generation)
        #expect(defaults.integer(forKey: "liveRung") == 1)
        // 採用したら前の接続は閉じる
        #expect(current.isCancelled)

        // 前の段が 0 以外 (720p → 360p が混んでいて 720p のまま)
        showFirstFrame(session)
        session.selectRung(3)
        loaders.last.onFailure?(busy)
        await waitUntil { session.selectedRung == 1 }
        #expect(rungParam(session.currentStreamURL) == "1")
        #expect(defaults.integer(forKey: "liveRung") == 1)

        // 形式の選択とは独立に組み合わせる
        session.selectQuality(.h264)
        let items = URLComponents(url: session.currentStreamURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "codec" }?.value == "h264")
        #expect(rungParam(session.currentStreamURL) == "1")
        session.close()
    }

    @Test func liveSecondRungChoiceReplacesTheTrial() async {
        let defaults = makeDefaults()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        let generation = session.generation
        session.selectRung(1)
        let first = loaders.last
        session.selectRung(3)
        let second = loaders.last
        #expect(first.isCancelled)

        // 捨てた試しの応答を処理し終えても、何も変わらない
        first.onReady?("h264", "1")
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(session.generation == generation)
        #expect(session.phase == .playing)
        #expect(session.selectedRung == 3)
        #expect(defaults.object(forKey: "liveRung") == nil)

        second.onReady?("h264", "3")
        await waitUntil { session.currentStreamURL == second.url }
        #expect(session.selectedRung == 3)
        #expect(defaults.integer(forKey: "liveRung") == 3)
        showFirstFrame(session)
        #expect(session.phase == .playing)
        session.close()
    }

    @Test func liveTrialIsDroppedWhenCurrentStreamReconnects() async {
        let defaults = makeDefaults()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        session.selectRung(2)
        let trial = loaders.last
        // 今の接続が切れて繋ぎ直しを予約した (待ちは 1 秒)
        current.onFailure?(StreamFailure(status: 500, message: nil, errorCode: nil))
        await waitUntil { session.phase == .reconnecting }
        #expect(trial.isCancelled)
        #expect(session.selectedRung == 0)

        // 予約のあと・開き直しの前に試しの応答が届いても採用しない
        trial.onReady?("h264", "2")
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(session.selectedRung == 0)
        #expect(defaults.object(forKey: "liveRung") == nil)
        session.close()
    }

    @Test func liveTrialClosedEmptyAfter200KeepsCurrentStream() async {
        let defaults = makeDefaults()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        session.selectRung(2)
        let trial = loaders.last
        trial.onResponse?("h264", "2")
        trial.onFinish?(true)
        await waitUntil { session.selectedRung == 0 }
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(!current.isCancelled)
        #expect(defaults.object(forKey: "liveRung") == nil)
        #expect(session.stop == nil)
        session.close()
    }

    @Test func liveTrialWithUnsupportedCodecKeepsCurrentStream() async {
        let defaults = makeDefaults()
        let (session, loaders) = await playingSession(defaults: defaults)
        let current = loaders.last
        session.selectRung(2)
        let trial = loaders.last
        trial.onResponse?("mpeg2", nil)
        trial.onReady?("mpeg2", nil)
        await waitUntil { session.selectedRung == 0 }
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(!current.isCancelled)
        #expect(trial.isCancelled)
        #expect(session.stop == nil)
        #expect(defaults.object(forKey: "liveRung") == nil)
        session.close()
    }

    @Test func liveRungIsRememberedAndOriginalClearsIt() async {
        let defaults = makeDefaults()
        let (first, loaders) = await playingSession(defaults: defaults)
        first.selectRung(3)
        loaders.last.onReady?("h264", "3")
        await waitUntil { defaults.integer(forKey: "liveRung") == 3 }
        first.close()

        let (second, secondLoaders) = await playingSession(defaults: defaults)
        #expect(second.selectedRung == 3)
        #expect(rungParam(second.currentStreamURL) == "3")
        second.selectRung(0)
        #expect(rungParam(secondLoaders.last.url) == nil)
        secondLoaders.last.onReady?("h264", nil)
        await waitUntil { defaults.object(forKey: "liveRung") == nil }
        second.close()
    }

    @Test func livePausedRungIsChosenWithoutTrying() async {
        let defaults = makeDefaults()
        let clock = Box(Date())
        let (session, loaders) = await playingSession(defaults: defaults, clock: { clock.value })
        session.pause()
        let count = loaders.all.count
        session.selectRung(2)
        // 一時停止はもう接続を閉じているので、試さずにそのまま選ぶ
        #expect(loaders.all.count == count)
        #expect(session.phase == .paused)
        #expect(session.selectedRung == 2)
        #expect(defaults.integer(forKey: "liveRung") == 2)
        // 押し直しは同じ押下ではない。時計を進めて間をあける
        clock.value = clock.value.addingTimeInterval(1)
        session.play()
        #expect(rungParam(session.currentStreamURL) == "2")
        session.close()
    }

    @Test func liveIgnoresUnknownRung() async {
        let (session, loaders) = await playingSession(defaults: makeDefaults())
        let count = loaders.all.count
        session.selectRung(4)
        session.selectRung(-1)
        #expect(session.selectedRung == 0)
        #expect(loaders.all.count == count)
        session.close()
    }

    @Test func busyWithoutRungChangeStillStops() {
        let session = makeSession { _ in }
        session.open(makeService(), liveCodecs: [.h264])
        for _ in 0..<4 { session.handleFailure(busy) }
        #expect(session.stop?.reason == .serverBusy)
        session.close()
    }

    @Test func liveTrialWithCodecRemovedFromSessionCandidatesKeepsCurrentStream() async {
        // 端末は H.265 に対応している扱い。この画面で H.265 がデコードできずに候補から外れたあと、
        // 段を下げた試しの応答が H.265 で来ても採用しない
        let defaults = makeDefaults()
        let loaders = Loaders()
        let session = makeSession(defaults: defaults, playable: [.h264, .hevc]) { loaders.all.append($0) }
        session.open(makeService(), liveCodecs: [.hevc, .h264])
        injectResponse(into: loaders.last, codec: "hevc")
        await waitUntil { session.currentCodec == .hevc }
        session.receive(RendererState(
            isPlaying: true, codec: "hvc1", position: 1, timeline: 1, buffered: 1,
            message: "decode failed", videoFailed: true, generation: session.generation
        ))
        // H.265 を外して、外した候補で開き直す
        await waitUntil { loaders.all.count == 2 }
        let current = loaders.last
        let playableParam = URLComponents(url: current.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "playable" }?.value
        #expect(playableParam == "h264")
        injectResponse(into: current, codec: "h264")
        await waitUntil { session.currentCodec == .h264 }
        showFirstFrame(session)

        session.selectRung(2)
        let trial = loaders.last
        #expect(trial !== current)
        trial.onReady?("hevc", "2")
        await waitUntil { session.selectedRung == 0 }
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(!current.isCancelled)
        #expect(trial.isCancelled)
        #expect(defaults.object(forKey: "liveRung") == nil)
        session.close()
    }

    @Test func livePauseDuringTrialCommitsChosenRung() async {
        let defaults = makeDefaults()
        let clock = Box(Date())
        let (session, loaders) = await playingSession(defaults: defaults, clock: { clock.value })
        session.selectRung(2)
        let trial = loaders.last
        session.pause()
        // 試しは捨てるが、選んだ段は残り、その場で覚える
        #expect(trial.isCancelled)
        #expect(session.phase == .paused)
        #expect(session.selectedRung == 2)
        #expect(defaults.integer(forKey: "liveRung") == 2)
        // 捨てた試しの応答が遅れて届いても何もしない
        trial.onReady?("h264", "2")
        await settle()
        #expect(session.phase == .paused)
        // 押し直しは同じ押下ではない。時計を進めて間をあける
        clock.value = clock.value.addingTimeInterval(1)
        session.play()
        #expect(rungParam(session.currentStreamURL) == "2")
        session.close()
    }
}
