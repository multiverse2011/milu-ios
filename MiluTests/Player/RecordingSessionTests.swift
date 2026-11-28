import Foundation
import Testing
@testable import Milu

@Suite @MainActor struct RecordingSessionTests {
    private func makeRecording() throws -> Recording {
        let json = """
        {"id":1,"title":"番組","name":"番組","serviceId":10,"serviceName":"局",
         "startAt":0,"endAt":60000,"durationMs":60000,"resumeMs":null,"watchedAt":null,
         "recording":false,"chase":null,"cmReliable":false,"poster":null,
         "files":[],"audio":"","audios":[]}
        """
        return try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
    }

    private func makeApp(_ transport: StubTransport) -> (AppModel, UserDefaults) {
        let name = "RecordingSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("http://127.0.0.1:3000", forKey: "serverURL")
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let app = AppModel(
            service: service,
            keychain: StubTokenStore(),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (app, defaults)
    }

    @Test func chase404StopsAfterThreeRetries() throws {
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: nil,
            kind: .chase
        )
        let notYet = StreamFailure(status: 404, message: "まだ録れていません", errorCode: nil)
        for _ in 0..<3 {
            session.handleFailure(notYet)
            #expect(session.stop == nil)
        }
        session.handleFailure(notYet)
        #expect(session.stop?.reason == .refused("まだ録れていません"))
    }

    @Test func receiveDropsStateFromAnotherGeneration() throws {
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: nil
        )
        // 開き直す前の古い状態。firstFrame にしない
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
        #expect(!session.finished)
    }

    /// 決定・再生/一時停止ボタンと Now Playing の toggle が両方届いても、1 度だけ切り替わる
    @Test func togglePlayCommandIgnoresTheSamePressTwice() async throws {
        let clock = Box(DispatchTime.now())
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/playback") == true {
                return reply(request, 200, Self.playbackJSON)
            }
            return reply(request, 200, "")
        }
        let (session, app) = try recordingSession(transport, clock: { clock.value })
        defer { withExtendedLifetime(app) {} }
        await session.start()
        report(1, to: session)
        #expect(session.isPlaying)

        // 決定で一時停止
        #expect(session.togglePlayCommand())
        #expect(!session.isPlaying)

        // 同じ押下が Now Playing から届いても、止まったまま
        clock.value = clock.value + 0.1
        #expect(session.togglePlayCommand())
        #expect(!session.isPlaying)

        // 間をあけた押下で再生する
        clock.value = clock.value + 1
        #expect(session.togglePlayCommand())
        #expect(session.isPlaying)

        await session.close()
    }

    @Test func nowPlayingPlayAndPauseIgnoreTheSamePressAsToggle() async throws {
        let clock = Box(DispatchTime.now())
        let backend = SpyNowPlayingBackend()
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/playback") == true {
                return reply(request, 200, Self.playbackJSON)
            }
            return reply(request, 200, "")
        }
        let (session, app) = try recordingSession(transport, backend: backend, clock: { clock.value })
        defer { withExtendedLifetime(app) {} }
        await session.start()
        report(1, to: session)
        #expect(session.isPlaying)

        #expect(session.togglePlayCommand())
        #expect(!session.isPlaying)
        clock.value = clock.value + 0.1
        #expect(backend.onPlay?() == true)
        #expect(!session.isPlaying)

        clock.value = clock.value + 1
        #expect(backend.onPlay?() == true)
        #expect(session.isPlaying)
        #expect(session.pause())
        #expect(!session.isPlaying)

        clock.value = clock.value + 1
        #expect(backend.onToggle?() == true)
        #expect(session.isPlaying)
        clock.value = clock.value + 0.1
        #expect(backend.onPause?() == true)
        #expect(session.isPlaying)

        clock.value = clock.value + 1
        #expect(backend.onPause?() == true)
        #expect(!session.isPlaying)
        #expect(session.play())
        #expect(session.isPlaying)

        await session.close()
    }

    private func recordingSession(
        _ transport: StubTransport,
        startStream: @escaping (StreamLoader) -> Void = { _ in },
        waitForChapterRetry: @escaping (Duration) async -> Void = { _ in },
        backend: SpyNowPlayingBackend = SpyNowPlayingBackend(),
        clock: @escaping () -> DispatchTime = { .now() }
    ) throws -> (RecordingSession, AppModel) {
        let (app, defaults) = makeApp(transport)
        let session = RecordingSession(
            baseURL: DemoServer.url,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: backend),
            startStream: startStream,
            waitForChapterRetry: waitForChapterRetry,
            clock: clock
        )
        return (session, app)
    }

    private func makeCommercialSession(
        startStream: @escaping (StreamLoader) -> Void = { _ in }
    ) async throws -> RecordingSession {
        let transport = StubTransport { request in
            switch request.url?.lastPathComponent {
            case "playback":
                return reply(request, 200, Self.playbackJSON)
            case "chapters":
                return reply(request, 200, """
                {"chapters":[{"start":10,"end":20,"title":"CM"},
                             {"start":20,"end":30,"title":"CM"},
                             {"start":40,"end":56,"title":"CM"},
                             {"start":57,"end":60,"title":"CM"}]}
                """)
            default:
                return reply(request, 200)
            }
        }
        let (session, app) = try recordingSession(transport, startStream: startStream)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        try await waitForChapters(in: session)
        try #require(session.chapters.count == 4)
        session.setCmSkip(true)
        return session
    }

    private nonisolated static let playbackJSON = """
    {"duration":60,"axis":"encoded","audios":[{"id":"0","label":"主音声"}],
     "offers":[{"codec":"h264","way":"stream"}]}
    """

    private func report(
        _ position: Double, to session: RecordingSession, isPlaying: Bool = true, buffered: Double = 5,
        recordingEndDrained: Bool = false
    ) {
        session.receive(RendererState(
            isPlaying: isPlaying, codec: "avc1", position: position, timeline: position,
            buffered: buffered, recordingEndDrained: recordingEndDrained,
            message: nil, generation: session.generation
        ))
    }

    private func waitForChapters(in session: RecordingSession) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while session.chapters.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func commercialSkipOffDoesNotSeek() async throws {
        let session = try await makeCommercialSession()
        let generation = session.generation
        session.setCmSkip(false)
        report(12, to: session)
        #expect(session.generation == generation)
        #expect(session.position == 12)
        await session.close()
    }

    @Test func commercialSkipIgnoresNonPlayingRendererState() async throws {
        let session = try await makeCommercialSession()
        let generation = session.generation
        session.setCmSkip(false)
        report(12, to: session)
        session.setCmSkip(true)
        report(12, to: session, isPlaying: false)
        #expect(session.generation == generation)
        #expect(session.position == 12)
        await session.close()
    }

    @Test func autoSkipDoesNotReopenTheSameCommercial() async throws {
        var startedURLs: [URL] = []
        let session = try await makeCommercialSession { startedURLs.append($0.url) }
        let generation = session.generation
        report(12, to: session)
        #expect(session.generation == generation + 1)
        #expect(session.position == 20)
        report(19, to: session)
        #expect(session.generation == generation + 1)
        #expect(session.phase == .playing)
        let fromValues = startedURLs.map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "from" })?.value
        }
        #expect(fromValues == ["0.000", "20.000"])
        await session.close()
    }

    @Test func autoSkipHandlesAdjacentCommercials() async throws {
        let session = try await makeCommercialSession()
        let generation = session.generation
        report(12, to: session)
        try #require(session.generation == generation + 1)
        try #require(session.position == 20)
        report(20, to: session)
        #expect(session.generation == generation + 2)
        #expect(session.position == 30)
        report(31, to: session)
        #expect(session.phase == .playing)
        #expect(session.position == 31)
        await session.close()
    }

    @Test func manualSeekLetsTheSameCommercialBeSkippedAgain() async throws {
        let session = try await makeCommercialSession()
        let initialGeneration = session.generation
        report(12, to: session)
        try #require(session.generation == initialGeneration + 1)
        try #require(session.position == 20)
        report(31, to: session)
        session.seek(to: 12)
        let generation = session.generation
        report(12, to: session)
        #expect(session.generation == generation + 1)
        #expect(session.position == 20)
        await session.close()
    }

    @Test func commercialEndingAtRecordingEndDoesNotSeek() async throws {
        let session = try await makeCommercialSession()
        let generation = session.generation
        // 録画終端の除外だけを検証するため、残りが 0.5 秒より長い CM を使う。
        report(58, to: session)
        #expect(session.generation == generation)
        #expect(session.position == 58)
        await session.close()
    }

    @Test func commercialSkipNearEndPlaysTheBufferedProgramAfterStreamFinishes() async throws {
        let session = try await makeCommercialSession()
        report(52, to: session)
        #expect(session.position == 56)
        // ストリームが、まだ本編を再生していないうちに全標本を送り終える。
        session.handleFinish(empty: false)
        #expect(!session.finished)
        report(56, to: session, buffered: 3)
        #expect(session.phase == .playing)
        report(58, to: session, buffered: 1)
        #expect(!session.finished)
        report(59, to: session, buffered: 0, recordingEndDrained: true)
        #expect(session.finished)
        await session.close()
    }

    @Test func initialChaptersAreRetriedAfterFailure() async throws {
        let attempts = Box(0)
        let transport = StubTransport { request in
            switch request.url?.lastPathComponent {
            case "playback":
                return reply(request, 200, Self.playbackJSON)
            case "chapters":
                attempts.value += 1
                if attempts.value == 1 { return reply(request, 500) }
                return reply(request, 200, #"{"chapters":[{"start":10,"end":20,"title":"CM"}]}"#)
            default:
                return reply(request, 200)
            }
        }
        let (session, app) = try recordingSession(transport)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        try await waitForChapters(in: session)
        #expect(attempts.value == 2)
        #expect(session.chapters.first?.end == 20)
        await session.close()
    }

    @Test func initialChapterRetriesUseBackoffAndStopAfterThreeRetries() async throws {
        let transport = StubTransport { request in reply(request, 500) }
        var delays: [Duration] = []
        let (session, app) = try recordingSession(transport, waitForChapterRetry: { delays.append($0) })
        defer { withExtendedLifetime(app) {} }
        await session.reloadChapters()
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(transport.requests.count == 4)
        #expect(session.chapters.isEmpty)
        await session.close()
    }

    @Test func olderChapterResponseCannotReplaceNewerChapters() async throws {
        let olderStarted = Box(false)
        let (releaseOlder, release) = AsyncStream<Void>.makeStream()
        let requests = Box(0)
        let transport = StubTransport { request in
            guard request.url?.lastPathComponent == "chapters" else { return reply(request, 200) }
            requests.value += 1
            if requests.value == 1 {
                olderStarted.value = true
                for await _ in releaseOlder { break }
                return reply(request, 200, #"{"chapters":[{"start":10,"end":20,"title":"CM"}]}"#)
            }
            return reply(request, 200, #"{"chapters":[{"start":10,"end":25,"title":"CM"}]}"#)
        }
        let (session, app) = try recordingSession(transport)
        defer { withExtendedLifetime(app) {} }
        let older = Task { await session.reloadChapters() }
        defer {
            release.finish()
            older.cancel()
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !olderStarted.value && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(olderStarted.value, "最初のチャプター取得が 2 秒以内に始まらなかった")
        await session.reloadChapters()
        #expect(session.chapters.first?.end == 25)
        release.yield(())
        await older.value
        #expect(session.chapters.first?.end == 25)
        await session.close()
    }

    @Test func closeStopsPlaybackBeforeWaitingForResume() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/resume") == true {
                // 応答しないサーバ。取り消されればすぐ戻る
                try? await Task.sleep(for: .seconds(10))
            }
            return reply(request, 200, "")
        }
        let (app, defaults) = makeApp(transport)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend())
        )
        // 最初のコマが映った状態にする (resume を送る対象)
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 10,
            timeline: 10,
            buffered: 0,
            message: nil,
            videoFailed: false,
            generation: 0
        ))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await session.close()
        }
        #expect(elapsed < .seconds(4))
        #expect(session.phase == .idle)
    }

    @Test func closeThenLateFailureDoesNotReopenOrSendResume() async throws {
        let transport = StubTransport { request in reply(request, 200, "") }
        let (app, defaults) = makeApp(transport)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults
        )
        await session.close()
        session.handleFailure(StreamFailure(status: nil, message: "切れました", errorCode: nil))
        // 遅れて届いた「最後まで観た」の状態。閉じた画面を起こさない
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 60,
            timeline: 60,
            buffered: 0,
            message: nil,
            videoFailed: false
        ))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.phase == .idle)
        #expect(!session.finished)
        #expect(!transport.requests.contains { $0.url?.path.hasSuffix("/resume") == true })
    }

    @Test func pictureInPictureOpeningInBackgroundDoesNotCloseWhilePaused() async throws {
        let transport = StubTransport { request in reply(request, 200, "") }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: nowPlaying
        )
        session.receive(RendererState(
            isPlaying: true, codec: "avc1", position: 12, timeline: 12, buffered: 5,
            message: nil, videoFailed: false, generation: 0
        ))
        session.enterBackground()
        #expect(nowPlaying.handlePause())
        #expect(session.phase == .paused)

        // 止めている間に窓が開いても、窓に出し続けるので接続と Now Playing は閉じない
        session.pictureInPictureDidChange(true)
        #expect(backend.info != nil)

        // 窓を閉じたら、止めているので閉じる (#32)
        session.pictureInPictureDidChange(false)
        #expect(backend.info == nil)

        await session.close()
    }

    @Test func backgroundKeepsPlayingWhenActiveAndClosesWhenPaused() async throws {
        let transport = StubTransport { request in reply(request, 200, "") }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: nowPlaying
        )

        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 12,
            timeline: 12,
            buffered: 5,
            message: nil,
            videoFailed: false,
            generation: 0
        ))
        #expect(session.phase == .playing)
        #expect(session.isPlaying)
        #expect(backend.info?.title == "番組")
        #expect(backend.info?.station == "局")
        #expect(backend.info?.rate == 1)

        // 再生中に裏へ回っても、止めずに再生と Now Playing を保つ
        session.enterBackground()
        #expect(session.inBackground)
        #expect(session.phase == .playing)
        #expect(session.isPlaying)
        #expect(backend.info?.rate == 1)

        // 裏で VideoToolbox が失敗を返しても再生を止めない
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 13,
            timeline: 13,
            buffered: 5,
            message: "gpu denied",
            videoFailed: true,
            generation: 0
        ))
        #expect(session.phase == .playing)
        #expect(session.stop == nil)

        // ロック画面の一時停止・再生が効く
        #expect(nowPlaying.handlePause())
        #expect(session.phase == .paused)
        #expect(!session.isPlaying)
        #expect(backend.info?.rate == 0)

        session.enterForeground()
        #expect(!session.inBackground)
        #expect(session.phase == .paused)

        // 一時停止中 (再生していない状態) で裏へ回ると接続を閉じ、Now Playing も消す
        session.enterBackground()
        #expect(session.phase == .paused)
        #expect(backend.info == nil)

        await session.close()
        #expect(backend.info == nil)
        #expect(!backend.commandsEnabled)
    }

    @Test func doesNotStealNowPlayingAndIgnoresStaleBackgroundVideoFailure() async throws {
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let otherOwner = UUID()
        nowPlaying.update(
            owner: otherOwner,
            item: NowPlayingItem(title: "別の再生", station: nil, isLive: true, isPlaying: true, rate: 1, position: nil, duration: nil),
            onPlay: { true },
            onPause: { true },
            onToggle: { true }
        )

        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: nil,
            nowPlaying: nowPlaying
        )
        // start() を呼ばずに直接 receive へ渡すので generation は初期値の 0
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 10,
            timeline: 10,
            buffered: 5,
            message: nil,
            videoFailed: false,
            generation: 0
        ))
        #expect(nowPlaying.currentOwner == otherOwner)
        #expect(backend.info?.title == "別の再生")

        // 裏→表をまたいで遅れて届いた古い videoFailed (videoEpoch == 0) は無視する
        session.enterBackground()
        session.enterForeground()
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 11,
            timeline: 11,
            buffered: 5,
            message: "stale gpu error",
            videoFailed: true,
            generation: 0
        ))
        #expect(session.phase == .playing)
        #expect(session.stop == nil)

        // pause でも他のセッションの Now Playing を奪わない
        session.pause()
        #expect(nowPlaying.currentOwner == otherOwner)
        #expect(backend.info?.rate == 1)

        await session.close()
    }

    @Test func reopensFromCurrentPositionWhenForegroundReplayCannotCoverNow() async throws {
        let playbackJSON = """
        {"duration":60,"axis":"encoded","audios":[{"id":"0","label":"主音声"}],
         "offers":[{"codec":"h264","way":"stream"}]}
        """
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/playback") == true {
                return reply(request, 200, playbackJSON)
            }
            return reply(request, 200, "")
        }
        let (app, defaults) = makeApp(transport)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend())
        )

        await session.start()
        let initialGeneration = session.generation
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 15,
            timeline: 15,
            buffered: 25,
            message: nil,
            videoFailed: false,
            generation: initialGeneration,
            videoEpoch: session.videoEpoch
        ))
        #expect(session.phase == .playing)

        // 短く裏に回って戻る。先読み済みで now 以前のキーフレームが控えに無く videoGap が届く
        session.enterBackground()
        session.enterForeground()
        let gapState = RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 18,
            timeline: 18,
            buffered: 22,
            message: nil,
            videoFailed: false,
            generation: initialGeneration,
            videoEpoch: session.videoEpoch,
            videoGap: true
        )
        session.receive(gapState)

        // いまの位置 (18 秒) から開き直す
        let reopenedGeneration = session.generation
        #expect(session.position == 18)
        #expect(session.phase == .loading)
        #expect(reopenedGeneration > initialGeneration)
        let streamURL = try #require(session.currentStreamURL)
        let queryItems = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.first(where: { $0.name == "from" })?.value == "18.000")

        // 同じ gap 状態をもう一度受け取っても開き直しが増えない
        session.receive(gapState)
        #expect(session.phase == .loading)
        #expect(session.generation == reopenedGeneration)

        await session.close()
    }

    @Test func reopensOnForegroundGapWhilePausedStaysPaused() async throws {
        let playbackJSON = """
        {"duration":60,"axis":"encoded","audios":[{"id":"0","label":"主音声"}],
         "offers":[{"codec":"h264","way":"stream"}]}
        """
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/playback") == true {
                return reply(request, 200, playbackJSON)
            }
            return reply(request, 200, "")
        }
        let (app, defaults) = makeApp(transport)
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend())
        )

        await session.start()
        let initialGeneration = session.generation
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 15,
            timeline: 15,
            buffered: 25,
            message: nil,
            videoFailed: false,
            generation: initialGeneration,
            videoEpoch: session.videoEpoch
        ))
        #expect(session.phase == .playing)

        // 再生中に裏へ回り、ロック画面などから一時停止したあと表へ戻る
        session.enterBackground()
        #expect(session.pause())
        #expect(session.phase == .paused)
        #expect(!session.isPlaying)
        session.enterForeground()

        // 控えで現在時刻を埋められず videoGap で開き直したあと、初コマが届いても一時停止のまま保つ
        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 18,
            timeline: 18,
            buffered: 22,
            message: nil,
            videoFailed: false,
            generation: initialGeneration,
            videoEpoch: session.videoEpoch,
            videoGap: true
        ))
        let reopenedGeneration = session.generation
        #expect(reopenedGeneration > initialGeneration)

        session.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 18,
            timeline: 18,
            buffered: 5,
            message: nil,
            videoFailed: false,
            generation: reopenedGeneration,
            videoEpoch: session.videoEpoch
        ))
        #expect(session.phase == .paused)
        #expect(!session.isPlaying)

        await session.close()
    }

    // MARK: 解像度 (段)

    /// 開いた接続を実際には繋がずに控える
    private final class Loaders {
        var all: [StreamLoader] = []
        var last: StreamLoader { all[all.count - 1] }
    }

    private func params(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
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

    private func makeRungSession(
        kind: RecordingSession.Kind,
        defaults: UserDefaults? = nil
    ) throws -> (RecordingSession, Loaders, AppModel, UserDefaults) {
        let transport = StubTransport { request in
            request.url?.lastPathComponent == "playback"
                ? reply(request, 200, Self.playbackJSON)
                : reply(request, 200)
        }
        let (app, madeDefaults) = makeApp(transport)
        let defaults = defaults ?? madeDefaults
        let loaders = Loaders()
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            kind: kind,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()),
            startStream: { loaders.all.append($0) }
        )
        return (session, loaders, app, defaults)
    }

    @Test func recordingRungIsTriedFromCurrentPositionAndKeptWhenBusy() async throws {
        let fixture = try streamFixture()
        let (session, loaders, app, _) = try makeRungSession(kind: .recording)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        let current = loaders.last
        #expect(current.url.path == "/api/recordings/1/stream")
        #expect(params(current.url)["rung"] == nil)
        #expect(session.rungItems.map(\.rung) == [0, 1, 2, 3])
        injectResponse(into: current)
        let delivered = countSamples(of: current)
        report(12, to: session)
        let generation = session.generation

        session.selectRung(3)
        let trial = loaders.last
        #expect(params(trial.url)["rung"] == "3")
        #expect(params(trial.url)["from"] == "12.000")
        // 自動なら、段を下げるコーデックはサーバが playable から選ぶ
        #expect(params(trial.url)["playable"] == "h264")
        #expect(params(trial.url)["codec"] == "h264")
        // 試している間も今の接続は閉じず、標本を渡し続ける
        #expect(session.currentStreamURL == current.url)
        #expect(!current.isCancelled)
        injectData(fixture, into: current)
        #expect(delivered.value > 0)

        trial.onFailure?(busy)
        await waitUntil { session.selectedRung == 0 }
        #expect(session.currentStreamURL == current.url)
        #expect(session.generation == generation)
        #expect(session.phase == .playing)
        #expect(session.isPlaying)
        #expect(session.stop == nil)
        #expect(loaders.all.count == 2)
        #expect(!current.isCancelled)
        let before = delivered.value
        injectData(fixture, into: current)
        #expect(delivered.value > before)
        await session.close()
    }

    @Test func recordingRungSwitchesWhenReadyAndKeepsPreviousNonZeroRungWhenBusy() async throws {
        let (session, loaders, app, _) = try makeRungSession(kind: .recording)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        let current = loaders.last
        report(12, to: session)
        session.selectRung(1)
        let trial = loaders.last
        // 試しの接続のヘッダは受けない (採用のときに 1 度だけ応答として扱う)
        #expect(trial.onResponse == nil)
        #expect(current.onResponse != nil)
        // ヘッダの 200 だけでは採用しない
        trial.onResponse?("h264", "1")
        await settle()
        #expect(session.currentStreamURL == current.url)

        trial.onReady?("h264", "1")
        await waitUntil { session.currentStreamURL == trial.url }
        #expect(params(session.currentStreamURL)["rung"] == "1")
        #expect(params(session.currentStreamURL)["from"] == "12.000")
        #expect(current.isCancelled)
        report(12.5, to: session)
        #expect(session.phase == .playing)
        #expect(session.isPlaying)

        // 720p → 360p が混んでいて 720p のまま
        session.selectRung(3)
        loaders.last.onFailure?(busy)
        await waitUntil { session.selectedRung == 1 }
        #expect(session.currentStreamURL == trial.url)

        session.selectRung(0)
        #expect(params(loaders.last.url)["rung"] == nil)
        #expect(params(loaders.last.url)["playable"] == nil)
        await session.close()
    }

    @Test func recordingTrialClosedEmptyAfter200KeepsCurrentStream() async throws {
        let (session, loaders, app, _) = try makeRungSession(kind: .recording)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        report(12, to: session)
        let current = loaders.last
        session.selectRung(2)
        let trial = loaders.last
        trial.onResponse?("h264", "2")
        trial.onFinish?(true)
        await waitUntil { session.selectedRung == 0 }
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(!current.isCancelled)
        #expect(session.isPlaying)
        await session.close()
    }

    @Test func reselectingCurrentRungOnlyDropsTheTrial() async throws {
        let (session, loaders, app, _) = try makeRungSession(kind: .recording)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        let current = loaders.last
        report(12, to: session)
        let generation = session.generation
        session.selectRung(1)
        let trial = loaders.last
        session.selectRung(0)
        // 新しい試しを開かず、今の接続・再生はそのまま
        #expect(loaders.all.count == 2)
        #expect(trial.isCancelled)
        #expect(!current.isCancelled)
        #expect(session.selectedRung == 0)
        trial.onReady?("h264", "1")
        await settle()
        #expect(session.currentStreamURL == current.url)
        #expect(session.generation == generation)
        #expect(session.isPlaying)
        await session.close()
    }

    @Test func pausedRungChangeStaysPausedForRecordingAndChase() async throws {
        for kind in [RecordingSession.Kind.recording, .chase] {
            let (session, loaders, app, _) = try makeRungSession(kind: kind)
            await session.start()
            report(12, to: session)
            session.pause()
            #expect(session.phase == .paused)
            let current = loaders.last

            // 混んでいたら、一時停止のまま今のストリームが残る
            session.selectRung(2)
            loaders.last.onFailure?(busy)
            await waitUntil { session.selectedRung == 0 }
            #expect(session.phase == .paused)
            #expect(session.currentStreamURL == current.url)
            #expect(!current.isCancelled)

            // 採用されたら、新しい接続・世代に切り替わり、一時停止のまま
            let generation = session.generation
            session.selectRung(2)
            let trial = loaders.last
            trial.onReady?("h264", "2")
            await waitUntil { session.currentStreamURL == trial.url && session.generation > generation }
            #expect(session.currentStreamURL == trial.url)
            #expect(session.generation > generation)
            #expect(current.isCancelled)
            report(12, to: session)
            #expect(session.phase == .paused)
            #expect(!session.isPlaying)
            await session.close()
            withExtendedLifetime(app) {}
        }
    }

    @Test func twoQuickRungChoicesKeepPlayingForRecordingAndChase() async throws {
        for kind in [RecordingSession.Kind.recording, .chase] {
            let (session, loaders, app, _) = try makeRungSession(kind: kind)
            await session.start()
            let current = loaders.last
            report(12, to: session)
            let generation = session.generation
            session.selectRung(1)
            let first = loaders.last
            session.selectRung(2)
            let second = loaders.last
            #expect(first.isCancelled)

            // 捨てた試しの応答を処理し終えても、何も変わらない
            first.onReady?("h264", "1")
            await settle()
            #expect(session.currentStreamURL == current.url)
            #expect(session.generation == generation)
            #expect(session.selectedRung == 2)
            #expect(session.isPlaying)

            second.onReady?("h264", "2")
            await waitUntil { session.currentStreamURL == second.url }
            report(12, to: session)
            #expect(session.phase == .playing)
            #expect(session.isPlaying)
            await session.close()
            withExtendedLifetime(app) {}
        }
    }

    @Test func recordingAndChaseStartFromOriginalEachTime() async throws {
        for kind in [RecordingSession.Kind.recording, .chase] {
            let (session, loaders, app, defaults) = try makeRungSession(kind: kind)
            await session.start()
            report(12, to: session)
            session.selectRung(3)
            loaders.last.onReady?("h264", "3")
            await waitUntil { session.currentStreamURL == loaders.last.url }
            #expect(params(session.currentStreamURL)["rung"] == "3")
            await session.close()

            // 同じ端末の設定で開き直しても覚えていない
            let (reopened, reopenedLoaders, reopenedApp, _) = try makeRungSession(kind: kind, defaults: defaults)
            await reopened.start()
            #expect(reopened.selectedRung == 0)
            #expect(params(reopenedLoaders.last.url)["rung"] == nil)
            await reopened.close()
            withExtendedLifetime((app, reopenedApp)) {}
        }
    }

    @Test func chaseRungIsTriedFromCurrentPosition() async throws {
        let (session, loaders, app, _) = try makeRungSession(kind: .chase)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        #expect(loaders.last.url.path == "/api/recordings/1/chase")
        report(30, to: session)
        #expect(session.position == 30)
        session.selectRung(1)
        #expect(params(loaders.last.url)["rung"] == "1")
        #expect(params(loaders.last.url)["from"] == "30.000")
        await session.close()
    }

    @Test func rungChosenBeforePlaybackArrivesIsUsedForFirstStream() async throws {
        // playback を返すのを止めておき、その間に段を選ぶ
        let gate = Box(false)
        let transport = StubTransport { request in
            if request.url?.lastPathComponent == "playback" {
                while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
                return reply(request, 200, Self.playbackJSON)
            }
            return reply(request, 200)
        }
        let (app, defaults) = makeApp(transport)
        defer { withExtendedLifetime(app) {} }
        let loaders = Loaders()
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            token: nil,
            recording: try makeRecording(),
            playable: [.h264],
            app: app,
            defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()),
            startStream: { loaders.all.append($0) }
        )
        let starting = Task { await session.start() }
        await waitUntil { transport.requests.contains { $0.url?.lastPathComponent == "playback" } }
        #expect(session.phase == .loading)

        session.selectRung(2)
        #expect(session.stop == nil)
        #expect(loaders.all.isEmpty)

        gate.value = true
        await starting.value
        #expect(session.stop == nil)
        #expect(loaders.all.count == 1)
        #expect(params(loaders.all.last?.url)["rung"] == "2")
        #expect(session.selectedRung == 2)
        await session.close()
    }

    // MARK: - 読み込みの失敗・音声・速度

    /// `playback` を読めなければ、サーバの言葉で止めてやり直せるようにする。やり直すと最初から読む
    @Test(arguments: [
        (500, #"{"error":"x","message":"録画が見つかりません"}"#, "録画が見つかりません"),
        (500, "", "再生できません"),
    ])
    func playbackFailureStopsWithMessageAndRetryReadsAgain(status: Int, body: String, expected: String) async throws {
        let fails = Box(true)
        let transport = StubTransport { request in
            guard request.url?.lastPathComponent == "playback" else { return reply(request, 200) }
            return fails.value ? reply(request, status, body) : reply(request, 200, Self.playbackJSON)
        }
        let loaders = Loaders()
        let (app, defaults) = makeApp(transport)
        defer { withExtendedLifetime(app) {} }
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!, token: nil, recording: try makeRecording(),
            playable: [.h264], app: app, defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()),
            startStream: { loaders.all.append($0) }
        )
        await session.start()
        #expect(session.stop == .init(reason: .refused(expected), retry: true))
        #expect(loaders.all.isEmpty)

        fails.value = false
        session.retry()
        await waitUntil { !loaders.all.isEmpty }
        #expect(session.stop == nil)
        #expect(loaders.last.url.path == "/api/recordings/1/stream")
        await session.close()
    }

    /// 音声を替えたら名前を覚え、今の位置から開き直す。同じ音声を選んでも開き直さない
    @Test func selectAudioRemembersNameAndReopens() async throws {
        let json = """
        {"duration":60,"axis":"encoded",
         "audios":[{"id":"0","label":"主音声"},{"id":"1","label":"副音声"}],
         "offers":[{"codec":"h264","way":"stream"}]}
        """
        let transport = StubTransport { request in
            request.url?.lastPathComponent == "playback" ? reply(request, 200, json) : reply(request, 200)
        }
        let loaders = Loaders()
        let (app, defaults) = makeApp(transport)
        defer { withExtendedLifetime(app) {} }
        let session = RecordingSession(
            baseURL: URL(string: "http://127.0.0.1:9")!, token: nil, recording: try makeRecording(),
            playable: [.h264], app: app, defaults: defaults,
            nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()),
            startStream: { loaders.all.append($0) }
        )
        await session.start()
        #expect(session.audioTracks.map(\.label) == ["主音声", "副音声"])
        let opened = loaders.all.count

        session.selectAudio(session.audioTracks[1])
        #expect(loaders.all.count == opened + 1)
        #expect(params(loaders.last.url)["audio"] == "1")
        #expect(defaults.string(forKey: "recordingAudioName") == "副音声")

        session.selectAudio(session.audioTracks[1])
        #expect(loaders.all.count == opened + 1)
        await session.close()
    }

    @Test func setSpeedKeepsTheChosenSpeed() async throws {
        let (session, loaders, app, _) = try makeRungSession(kind: .recording)
        defer { withExtendedLifetime(app) {} }
        await session.start()
        let opened = loaders.all.count
        session.setSpeed(2)
        #expect(session.speed == 2)
        // 速度は開き直さずに替える
        #expect(loaders.all.count == opened)
        await session.close()
    }
}
