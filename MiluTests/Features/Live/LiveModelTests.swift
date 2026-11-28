import Foundation
import Testing
@testable import Milu

@Suite @MainActor struct LiveModelTests {
    nonisolated private static let servicesJSON = """
    [
      {"id":10,"type":"GR","name":"NHK総合","remoteControlKey":1,"logo":null,
       "live":"api/services/10/live","airing":true,"video":true,"now":null},
      {"id":20,"type":"GR","name":"Eテレ","remoteControlKey":2,"logo":null,
       "live":"api/services/20/live","airing":true,"video":true,"now":null}
    ]
    """

    private func makeApp(_ transport: StubTransport, serverURL: URL = URL(string: "http://127.0.0.1:9")!) -> (AppModel, UserDefaults) {
        let name = "LiveModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(serverURL.absoluteString, forKey: "serverURL")
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

    private func makeServicesTransport() -> StubTransport {
        StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, Self.servicesJSON)
            }
            return reply(request, 200, "{}")
        }
    }

    /// stop のあとに始まった reload は通信もしない (閉じた接続を開き直さない)
    @Test func reloadDoesNothingAfterStop() async {
        let transport = StubTransport { request in reply(request, 200, "[]") }
        let (app, defaults) = makeApp(transport)
        let model = LiveModel(defaults: defaults, isPhone: true)

        await model.start(app)
        let started = transport.requests.count
        #expect(started > 0)

        model.stop()
        await model.reload()

        #expect(transport.requests.count == started)
    }

    /// 自動横画面がオフ (既定) のときは、ライブを開いても局を替えても埋め込みのまま
    @Test func autoLandscapeOffStartsEmbedded() async {
        let (app, defaults) = makeApp(makeServicesTransport())
        let model = LiveModel(defaults: defaults, isPhone: true)
        defer { model.stop() }

        await model.start(app)
        #expect(model.load == .ready)
        #expect(!model.showFullscreen)

        model.select(model.services[1])
        #expect(!model.showFullscreen)
    }

    #if os(iOS)
    /// 自動横画面がオンのときは全画面で始まり、「全画面をやめる」で戻ったあと reload では勝手に戻らず、別局の再生でまた全画面になる
    @Test func autoLandscapeOnStartsFullscreenAndAllowsExit() async {
        let (app, defaults) = makeApp(makeServicesTransport())
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        let model = LiveModel(defaults: defaults, isPhone: true)
        defer {
            model.stop()
            OrientationLock.shared.lock(.portrait, isPhone: false)
        }

        await model.start(app)
        #expect(model.load == .ready)
        #expect(model.showFullscreen)

        // 「全画面をやめる」で縦に戻る
        model.showFullscreen = false
        await model.reload()
        #expect(!model.showFullscreen)

        // 別の局を選んで再生を始めると全画面で開く
        model.select(model.services[1])
        #expect(model.showFullscreen)
    }

    /// 全画面をやめたあと、scenePhase の inactive→active (stop→start) だけでは全画面に戻らない
    @Test func scenePhaseResumeDoesNotReenterFullscreen() async {
        let (app, defaults) = makeApp(makeServicesTransport())
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        let model = LiveModel(defaults: defaults, isPhone: true)
        defer {
            model.stop()
            OrientationLock.shared.lock(.portrait, isPhone: false)
        }

        await model.start(app)
        #expect(model.showFullscreen)

        // 「全画面をやめる」で縦に戻す
        model.showFullscreen = false

        // コントロールセンター等で inactive → active になって再開しても、縦のまま
        model.stop()
        await model.start(app)
        #expect(!model.showFullscreen)

        // ほかのタブへ移ってライブのタブに戻ったときは「始めた」として全画面で開く
        model.setTabSelected(false)
        model.stop()
        model.setTabSelected(true)
        await model.start(app)
        #expect(model.showFullscreen)

        // 番組表の「ライブで観る」も全画面で開く
        model.showFullscreen = false
        model.watch(serviceID: 10)
        #expect(model.showFullscreen)
    }
    #endif

    #if os(iOS)
    /// 観られる局が無いときは自動横画面がオンでも全画面を開かない
    @Test func autoLandscapeOnDoesNotOpenWhenEmpty() async {
        let transport = StubTransport { request in reply(request, 200, "[]") }
        let (app, defaults) = makeApp(transport)
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        let model = LiveModel(defaults: defaults, isPhone: true)
        defer { model.stop() }

        await model.start(app)
        #expect(model.load == .empty)
        #expect(!model.showFullscreen)
    }

    /// iPad・Mac では自動横画面がオンでも全画面を開かない
    @Test func autoLandscapeOnIgnoredWhenNotPhone() async {
        let (app, defaults) = makeApp(makeServicesTransport())
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        let model = LiveModel(defaults: defaults, isPhone: false)
        defer { model.stop() }

        await model.start(app)
        #expect(model.load == .ready)
        #expect(!model.showFullscreen)

        model.select(model.services[1])
        #expect(!model.showFullscreen)
    }
    #endif

    @Test func lifecycleKeepsPlayingLiveInBackgroundAndStopsNonPlayingOrDeselected() async {
        let servicesJSON = """
        [{"id":101,"type":"GR","name":"NHK","remoteControlKey":1,"logo":null,
          "live":"/api/services/101/live","airing":true,"video":true,
          "now":{"id":1,"title":"ニュース","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/api/services") == true {
                return reply(request, 200, servicesJSON)
            }
            return reply(request, 200, "{\"liveCodecs\":[\"h264\"],\"hevc\":false}")
        }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let model = LiveModel(defaults: defaults, nowPlaying: nowPlaying)

        await model.start(app)
        let session = try! #require(model.session)
        #expect(session.phase == .loading)

        // まだ再生が始まっていない (.loading) うちに裏へ回ったら、接続も全画面も閉じる
        model.showFullscreen = true
        model.handleLifecycle(isSelected: true, appPhase: .background, app: app)
        #expect(!model.started)
        #expect(!model.showFullscreen)
        #expect(session.phase == .idle)

        // 再び開いて再生中にする
        await model.start(app)
        let playingSession = try! #require(model.session)
        playingSession.receive(RendererState(
            isPlaying: true,
            codec: "avc1",
            position: 1,
            timeline: 1,
            buffered: 1,
            message: nil,
            videoFailed: false,
            generation: playingSession.generation
        ))
        #expect(playingSession.phase == .playing)

        // 再生中に裏へ回ったら、全画面も接続も保つ
        model.showFullscreen = true
        model.handleLifecycle(isSelected: true, appPhase: .background, app: app)
        #expect(model.started)
        #expect(model.showFullscreen)
        #expect(playingSession.inBackground)
        #expect(playingSession.phase == .playing)

        // 表に戻ったら映像の層だけ戻す
        model.handleLifecycle(isSelected: true, appPhase: .active, app: app)
        #expect(!playingSession.inBackground)

        // タブを離れたら、再生中でも閉じる
        model.handleLifecycle(isSelected: false, appPhase: .active, app: app)
        #expect(!model.started)
        #expect(!model.showFullscreen)
        #expect(playingSession.phase == .idle)
        #expect(backend.info == nil)
    }

    @Test func reloadWhilePausedDoesNotAutoOpenWhenCurrentDisappears() async {
        let initialJSON = """
        [{"id":101,"type":"GR","name":"NHK","remoteControlKey":1,"logo":null,
          "live":"/api/services/101/live","airing":true,"video":true,
          "now":{"id":1,"title":"番組1","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}},
         {"id":102,"type":"GR","name":"Eテレ","remoteControlKey":2,"logo":null,
          "live":"/api/services/102/live","airing":true,"video":true,
          "now":{"id":2,"title":"番組2","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let afterJSON = """
        [{"id":102,"type":"GR","name":"Eテレ","remoteControlKey":2,"logo":null,
          "live":"/api/services/102/live","airing":true,"video":true,
          "now":{"id":2,"title":"番組2","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let serveAfter = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/api/services") == true {
                return reply(request, 200, serveAfter.value ? afterJSON : initialJSON)
            }
            return reply(request, 200, "{\"liveCodecs\":[\"h264\"],\"hevc\":false}")
        }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let model = LiveModel(defaults: defaults, nowPlaying: nowPlaying)

        await model.start(app)
        model.select(model.services.first { $0.id == 101 }!)
        let session = try! #require(model.session)
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

        // 一時停止中に 101 が放送休止で一覧から消えても、102 を勝手に open しない
        serveAfter.value = true
        await model.reload()
        #expect(model.current?.id == 102)
        #expect(session.phase == .paused)
        #expect(backend.info?.rate == 0)

        // stop の二重呼びでも壊れない (タブ切替と onDisappear の重なり)
        model.stop()
        model.stop()
        #expect(!model.started)
        #expect(backend.info == nil)
    }

    /// 番組表の「ライブで観る」が start より先に来ても、同じ局を 2 回 open しない (#72)
    @Test func watchBeforeStartOpensOnce() async {
        // 接続先をデモにする (API とストリームをデモが返す)。ストリームがデモなら
        // 繋ぎ直しで世代が進まないので、open の回数を世代で数えられる
        let (app, defaults) = makeApp(StubTransport { reply($0, 200, "{}") }, serverURL: DemoServer.url)
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))

        // ライブのタブを開くより先に、番組表の「ライブで観る」が届く。
        // 先頭でない局 (104) を指定し、watch が捨てられていないことも見る
        model.watch(serviceID: 104)
        await model.start(app)

        let session = try! #require(model.session)
        #expect(model.current?.id == 104)
        // open は 1 回だけ。世代は open・startStream・attach で 1 回につき 3 進む (内部の進み方に依る)
        #expect(session.generation == 3)
        model.stop()
    }

    /// 一覧で再生を止めたまま裏へ回って戻っても、勝手に再生しない (#72)
    @Test func closePlaybackStaysClosedOnSceneResume() async {
        let (app, defaults) = makeApp(StubTransport { reply($0, 200, "{}") }, serverURL: DemoServer.url)
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))

        await model.start(app)
        let session = try! #require(model.session)
        model.closePlayback()
        #expect(!model.isPlaybackOpen)

        // 再生していないので、裏へ回ると .stop → 表へ戻ると .activate (start)
        model.handleLifecycle(isSelected: true, appPhase: .background, app: app)
        #expect(!model.started)
        model.handleLifecycle(isSelected: true, appPhase: .active, app: app)
        for _ in 0..<100 where !(model.started && model.load == .ready) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(!model.isPlaybackOpen)
        #expect(session.phase == .idle)
        model.stop()
    }

    /// タブを離れて入り直したら、一覧で止めていても再生を始める (#72)
    @Test func closePlaybackStartsAgainAfterTabReentry() async {
        let (app, defaults) = makeApp(StubTransport { reply($0, 200, "{}") }, serverURL: DemoServer.url)
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))

        await model.start(app)
        model.closePlayback()
        #expect(!model.isPlaybackOpen)

        model.setTabSelected(false)
        model.handleLifecycle(isSelected: false, appPhase: .active, app: app)
        #expect(!model.started)

        model.setTabSelected(true)
        await model.start(app)
        #expect(model.isPlaybackOpen)
        model.stop()
    }

    /// 止まっている間に「ライブで観る」が届いても、start してから 1 回だけ開き、説明も埋まる (#72)
    @Test func watchWhileStoppedWaitsForStart() async {
        let (app, defaults) = makeApp(StubTransport { reply($0, 200, "{}") }, serverURL: DemoServer.url)
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))

        await model.start(app)
        model.stop()
        let session = try! #require(model.session)

        // 止まっている間は開かない (start の loadServices から改めて適用する)
        model.watch(serviceID: 104)
        #expect(!model.isPlaybackOpen)

        let before = session.generation
        await model.start(app)
        #expect(model.current?.id == 104)
        // start で開いた 1 回だけ (1 回で世代は 3 進む)
        #expect(session.generation == before + 3)

        // 説明 (api/programs/<id>) を取りこぼさない
        for _ in 0..<100 where model.currentDescription.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.currentDescription.isEmpty)
        model.stop()
    }

    /// 録画の知らせは、再生の画面を閉じたら持ち越さない (#72)。
    /// 閉じたあとに届いた失敗は、一覧の側で出すために残す (#88)
    @Test func closingPlaybackDropsRecordingAlerts() async {
        let (app, defaults) = makeApp(StubTransport { reply($0, 200, "{}") }, serverURL: DemoServer.url)
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))

        await model.start(app)
        model.recordAlert = "録画できません"
        model.showStopRecording = true
        model.closePlayback()
        #expect(model.recordAlert == nil)
        #expect(!model.showStopRecording)

        // 閉じたあと (cover が消えている間) に届いた失敗は、一覧の側で出すために残す (#88)
        model.recordAlert = "録画を停止できません"
        model.closePlayback()
        #expect(model.recordAlert == "録画を停止できません")

        // 次に開いたときには古い知らせを出さない
        model.openPlayback(model.services[0])
        #expect(model.isPlaybackOpen)
        #expect(model.recordAlert == nil)
        model.stop()
    }

    /// tvOS の再生画面を閉じても、モデルと一覧は開いたまま。一覧の更新で勝手に開き直さず、
    /// 次の局を選んだときに開き直す (#72)
    @Test func closePlaybackKeepsTheListAndReopensOnSelection() async {
        let servicesJSON = """
        [{"id":101,"type":"GR","name":"NHK","remoteControlKey":1,"logo":null,
          "live":"/api/services/101/live","airing":true,"video":true,
          "now":{"id":1,"title":"ニュース","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/api/services") == true {
                return reply(request, 200, servicesJSON)
            }
            return reply(request, 200, "{\"liveCodecs\":[\"h264\"],\"hevc\":false}")
        }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let model = LiveModel(defaults: defaults, nowPlaying: NowPlayingController(backend: backend))

        await model.start(app)
        let session = try! #require(model.session)
        #expect(model.isPlaybackOpen)
        // 映ると Now Playing が出る
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
        #expect(backend.info != nil)

        // 再生の画面を閉じても、一覧とモデルはそのまま。Now Playing は消える
        model.closePlayback()
        #expect(!model.isPlaybackOpen)
        #expect(session.phase == .idle)
        #expect(backend.info == nil)
        #expect(model.load == .ready)
        #expect(model.current?.id == 101)

        // 一覧の更新 (SSE) では開き直さない
        await model.reload()
        #expect(!model.isPlaybackOpen)
        #expect(session.phase == .idle)

        // 一覧で局を選ぶと開き直す
        model.openPlayback(model.services[0])
        #expect(model.isPlaybackOpen)
        #expect(session.phase == .loading)

        // 番組表の「ライブで観る」でも開き直す
        model.closePlayback()
        #expect(!model.isPlaybackOpen)
        model.watch(serviceID: 101)
        #expect(model.isPlaybackOpen)
        #expect(session.phase == .loading)

        model.stop()
    }

    @Test func reloadsToEmptyClosesAndReopensWhenServicesReturn() async {
        let servicesJSON = """
        [{"id":101,"type":"GR","name":"NHK","remoteControlKey":1,"logo":null,
          "live":"/api/services/101/live","airing":true,"video":true,
          "now":{"id":1,"title":"ニュース","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let isEmpty = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/api/services") == true {
                return reply(request, 200, isEmpty.value ? "[]" : servicesJSON)
            }
            return reply(request, 200, "{\"liveCodecs\":[\"h264\"],\"hevc\":false}")
        }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let model = LiveModel(defaults: defaults, nowPlaying: nowPlaying)

        await model.start(app)
        let session = try! #require(model.session)
        let firstGeneration = session.generation
        #expect(model.load == .ready)
        #expect(session.phase == .loading)

        // 0 件になったらセッションを閉じて .empty にする
        isEmpty.value = true
        await model.reload()
        #expect(model.load == .empty)
        #expect(model.current == nil)
        #expect(session.phase == .idle)

        // 局が戻って .ready になったら、閉じたままにせず開き直す
        isEmpty.value = false
        await model.reload()
        #expect(model.load == .ready)
        #expect(model.current?.id == 101)
        #expect(session.phase == .loading)
        #expect(session.generation > firstGeneration)

        model.stop()
    }

    @Test func pausedThroughEmptyAndBackStaysPausedWithoutReopening() async {
        let servicesJSON = """
        [{"id":101,"type":"GR","name":"NHK","remoteControlKey":1,"logo":null,
          "live":"/api/services/101/live","airing":true,"video":true,
          "now":{"id":1,"title":"ニュース","startAt":0,"endAt":1800000,"reserved":false,"recording":false,"audios":[]}}]
        """
        let isEmpty = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/api/services") == true {
                return reply(request, 200, isEmpty.value ? "[]" : servicesJSON)
            }
            return reply(request, 200, "{\"liveCodecs\":[\"h264\"],\"hevc\":false}")
        }
        let (app, defaults) = makeApp(transport)
        let backend = SpyNowPlayingBackend()
        let nowPlaying = NowPlayingController(backend: backend)
        let model = LiveModel(defaults: defaults, nowPlaying: nowPlaying)

        await model.start(app)
        let session = try! #require(model.session)
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
        #expect(session.pause())
        let pausedGeneration = session.generation
        #expect(session.phase == .paused)

        // 一時停止中に 0 件になっても close せず .paused を保つ
        isEmpty.value = true
        await model.reload()
        #expect(model.load == .empty)
        #expect(session.phase == .paused)
        #expect(session.generation == pausedGeneration)

        // 局が戻って .ready になっても勝手に開き直さず .paused のまま updateService だけ行う
        isEmpty.value = false
        await model.reload()
        #expect(model.load == .ready)
        #expect(model.current?.id == 101)
        #expect(session.phase == .paused)
        #expect(session.generation == pausedGeneration)
        #expect(backend.info?.rate == 0)

        model.stop()
    }

    #if os(iOS)
    /// #39 と #32 の両立: 全画面をやめたあと、inactive では止めず、inactive→active や background→active でも勝手に全画面へ戻らない
    @Test func handleLifecycleKeepsActiveOnInactiveAndDoesNotReenterFullscreenOnSceneResume() async throws {
        let (app, defaults) = makeApp(makeServicesTransport())
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        let model = LiveModel(defaults: defaults, isPhone: true, nowPlaying: NowPlayingController(backend: SpyNowPlayingBackend()))
        defer {
            model.stop()
            OrientationLock.shared.lock(.portrait, isPhone: false)
        }

        model.handleLifecycle(isSelected: true, appPhase: .active, app: app)
        await waitUntil { model.session != nil }
        let session = try #require(model.session)
        #expect(model.showFullscreen)

        // 「全画面をやめる」で縦に戻す
        model.showFullscreen = false

        // inactive になっても止めず、active に戻っても全画面には戻らない
        model.handleLifecycle(isSelected: true, appPhase: .inactive, app: app)
        #expect(model.started)
        #expect(!model.showFullscreen)
        model.handleLifecycle(isSelected: true, appPhase: .active, app: app)
        #expect(model.started)
        #expect(!model.showFullscreen)

        // 非再生 (.loading) で background に入って閉じたあと、同じタブのまま active に戻っても全画面には戻らない
        model.handleLifecycle(isSelected: true, appPhase: .background, app: app)
        #expect(!model.started)
        model.handleLifecycle(isSelected: true, appPhase: .active, app: app)
        await waitUntil { model.started && session.phase != .idle }
        #expect(model.started)
        #expect(!model.showFullscreen)
    }
    #endif
}
