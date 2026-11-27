import Foundation
import Testing
@testable import Milu

@Suite struct DemoTests {
    private func makeModel(
        transport: StubTransport = StubTransport { req in reply(req, 500, "") },
        defaults existingDefaults: UserDefaults? = nil
    ) -> (AppModel, StubTransport, UserDefaults, String) {
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let name = "DemoTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        if let existingDefaults {
            defaults = existingDefaults
        } else {
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }
        let model = AppModel(
            service: service,
            keychain: StubTokenStore(),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (model, transport, defaults, name)
    }

    @Test func startDemoPersistsAcrossRelaunchWithoutNetwork() async throws {
        let (model, transport, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(999, forKey: "lastServiceID")
        model.requestLiveWatch(serviceID: 999)
        model.startDemo()
        #expect(model.isDemo)
        #expect(model.phase == .connected)
        #expect(model.server?.displayName == "デモ")
        #expect(model.address.isEmpty)
        #expect(model.liveWatch == nil)
        #expect(defaults.integer(forKey: "lastServiceID") == 999)
        #expect(defaults.string(forKey: "serverURL") == DemoServer.url.absoluteString)

        // API を呼んでも本番の HTTPTransport には 1 件も流れない
        let data = try await model.get("api/services")
        let services = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data)
        #expect(services.count == 4)
        #expect(transport.requests.isEmpty)

        // 再起動相当: 同じ UserDefaults から作り直してもデモ中のまま復元される
        let (relaunched, _, _, _) = makeModel(transport: transport, defaults: defaults)
        #expect(relaunched.isDemo)
        #expect(relaunched.phase == .connected)
        #expect(relaunched.server?.displayName == "デモ")
        #expect(relaunched.address.isEmpty)
    }

    @Test func signOutFromDemoClearsStateWithoutLogoutRequest() async {
        let (model, transport, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        model.startDemo()
        defaults.set(101, forKey: "lastServiceID")
        model.requestLiveWatch(serviceID: 101)

        await model.signOut()
        #expect(!model.isDemo)
        #expect(model.server == nil)
        #expect(model.phase == .idle)
        #expect(model.address.isEmpty)
        #expect(model.liveWatch == nil)
        #expect(defaults.string(forKey: "serverURL") == nil)
        #expect(defaults.object(forKey: "lastServiceID") == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func reconnectFromDemoSwitchesToRealServerAndClearsDemoState() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, "[]")
            }
            return reply(request, 200, #"{"ok":true}"#)
        }
        let (model, _, defaults, suite) = makeModel(transport: transport)
        defer { defaults.removePersistentDomain(forName: suite) }

        model.startDemo()
        defaults.set(102, forKey: "lastServiceID")
        model.requestLiveWatch(serviceID: 102)

        let error = await model.reconnect("http://127.0.0.1:3000")
        #expect(error == nil)
        #expect(!model.isDemo)
        #expect(model.server?.url == URL(string: "http://127.0.0.1:3000"))
        #expect(model.address == "127.0.0.1:3000")
        #expect(model.liveWatch == nil)
        #expect(defaults.object(forKey: "lastServiceID") == nil)

        // 切り替え後は本番側の transport が使われる
        let body = try await model.get("api/playback/options")
        #expect(body == Data(#"{"ok":true}"#.utf8))
    }

    @Test func demoServicesGuideAndRecordingsCoverRequiredCases() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let client = DenpaClient(baseURL: DemoServer.url, token: nil, transport: DemoTransport(now: { fixedNow }))

        // 局の一覧 (3〜4 局、すべて放送中の番組あり)
        let servicesData = try await client.send("api/services")
        let services = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: servicesData)
        #expect((3...4).contains(services.count))
        #expect(services.allSatisfy { $0.airing && $0.video && $0.now != nil })

        // 今日と明日の番組表・ジャンル分散・詳細
        let today = GuideLayout.broadcastDay(for: fixedNow)
        let tomorrow = GuideLayout.calendar.date(byAdding: .day, value: 1, to: today)!
        for day in [today, tomorrow] {
            let range = GuideLayout.broadcastRange(for: day)
            let guideData = try await client.send("api/programs?type=GR&from=\(range.from)&to=\(range.to)")
            let guide = try JSONDecoder().decode(GuideResponse.self, from: guideData)
            #expect(guide.services.count == services.count)
            #expect(guide.services.allSatisfy { !$0.programs.isEmpty })

            let days = GuideLayout.menuDays(now: fixedNow, until: guide.until)
            #expect(days.count == 2)

            let genres = Set(guide.services.flatMap(\.programs).compactMap(\.genre))
            #expect(genres.count >= 5)

            let sampleProgram = try #require(guide.services.first?.programs.first)
            let detailData = try await client.send("api/programs/\(sampleProgram.id)")
            let detail = try JSONDecoder().decode(ProgramDetail.self, from: detailData)
            #expect(detail.name == sampleProgram.name)
        }

        // 録画 (6〜10 本、未視聴・途中まで観た・観た を混ぜる)
        let recData = try await client.send("api/recordings?limit=50&offset=0")
        let recordings = try JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: recData)
        #expect((6...10).contains(recordings.count))
        #expect(recordings.contains { $0.resumeMs == nil && $0.watchedAt == nil })
        #expect(recordings.contains { $0.resumeMs != nil && $0.watchedAt == nil })
        #expect(recordings.contains { $0.resumeMs == nil && $0.watchedAt != nil })

        for rec in recordings {
            let detail = try JSONDecoder().decode(
                RecordingDetail.self,
                from: try await client.send("api/recordings/\(rec.id)/detail")
            )
            #expect(detail.id == rec.id)
            let playback = try JSONDecoder().decode(
                Playback.self,
                from: try await client.send("api/recordings/\(rec.id)/playback")
            )
            #expect(playback.duration > 0)
            #expect(PlaybackRules.selectRecordingOffer(offers: playback.offers, playable: [.h264]) != nil)
            let chapters = try JSONDecoder().decode(
                Chapters.self,
                from: try await client.send("api/recordings/\(rec.id)/chapters")
            )
            #expect(!chapters.chapters.isEmpty)
        }
    }

    @Test func demoSearchFindsRecordingsAndProgramsByStationName() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let client = DenpaClient(baseURL: DemoServer.url, token: nil, transport: DemoTransport(now: { fixedNow }))

        let response = try JSONDecoder().decode(
            SearchResponse.self,
            from: try await client.send(SearchModel.path(query: "あおば"))
        )
        #expect(response.q == "あおば")
        #expect(!response.recordings.rows.isEmpty)
        #expect(response.recordings.rows.allSatisfy { $0.serviceName == "あおばTV" })

        // 行の録画は一覧の本物の行 (開く経路と同じ id・同じ開始時刻) として見つかる
        let list = try await client.send("api/recordings?limit=100&offset=0")
        let recordings = try JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: list)
        for row in response.recordings.rows {
            let real = try #require(recordings.first { $0.id == row.id })
            #expect(real.startAt == row.startAt)
            #expect(row.watch != nil)
            #expect(row.playable)
        }

        // これからの放送も同じ id で詳細を開ける
        #expect(!response.programs.rows.isEmpty)
        #expect(response.programs.rows.allSatisfy { $0.serviceName == "あおばTV" })
        for row in response.programs.rows {
            #expect(row.startAt < row.endAt)
            _ = try await client.send("api/programs/\(row.id)")
        }

        // 当たらない言葉は空
        let none = try JSONDecoder().decode(
            SearchResponse.self,
            from: try await client.send(SearchModel.path(query: "ぜったいにない言葉"))
        )
        #expect(none.isEmpty)

        // 件数は `limit` で切り、続きがあることを `more` で返す
        // 「港」は録画 2 本、「アニメ」はこれからの放送が 2 本以上に当たる
        let limitedRecordings = try JSONDecoder().decode(
            SearchResponse.self,
            from: try await client.send(SearchModel.path(query: "港", limit: 1))
        )
        #expect(limitedRecordings.recordings.rows.count == 1)
        #expect(limitedRecordings.recordings.more)

        let limitedPrograms = try JSONDecoder().decode(
            SearchResponse.self,
            from: try await client.send(SearchModel.path(query: "アニメ", limit: 1))
        )
        #expect(limitedPrograms.programs.rows.count == 1)
        #expect(limitedPrograms.programs.more)

        // 予約済みの番組は番組表と同じ状態で返る
        let reserved = try JSONDecoder().decode(
            SearchResponse.self,
            from: try await client.send(SearchModel.path(query: "ことばの迷宮"))
        )
        #expect(reserved.programs.rows.contains { $0.reservationState == "scheduled" })
    }

    /// デモの検索の画面が「denpa に接続できません」にならず、録画の行から観る画面まで進めること (#73)
    @Test func demoSearchShowsResultsAndOpensRecording() async throws {
        let (app, _, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        app.startDemo()

        let model = SearchModel(debounce: .zero)
        defer { model.stop() }
        await model.start(app)

        let task = model.setQuery("あおば")
        await task?.value

        #expect(model.load == .ready)
        let section = try #require(model.recordingResults)
        let row = try #require(section.rows.first)
        #expect(row.serviceName == "あおばTV")
        #expect(model.results?.programs.rows.isEmpty == false)

        // 一覧の本物の行として開ける (デモの一覧に同じ id がある)
        await model.openRecording(id: row.id)
        #expect(model.openError == nil)
        #expect(model.openRequest != nil)
    }

    @Test func demoScheduleCoversFullBroadcastDayWithoutGaps() async throws {
        let baseNow = Date(timeIntervalSince1970: 1_795_000_000)
        let today = GuideLayout.broadcastDay(for: baseNow)
        let todayRange = GuideLayout.broadcastRange(for: today)

        // 放送日の 04:00 から 30 分刻みで 48 時点すべてに全 4 局の放送中番組 (now) があること
        for step in 0..<48 {
            let pointMs = todayRange.from + Int64(step) * 30 * 60_000
            let point = Date(timeIntervalSince1970: Double(pointMs) / 1000)
            let client = DenpaClient(baseURL: DemoServer.url, token: nil, transport: DemoTransport(now: { point }))
            let services = try JSONDecoder().decodeArrayDroppingUnknowns(
                [Service].self,
                from: try await client.send("api/services")
            )
            #expect(services.count == 4)
            #expect(services.allSatisfy { $0.now != nil }, "step=\(step) で now が欠けている局がある")
        }

        // 今日・明日の各局の番組が from〜to を穴なく覆うこと
        let client = DenpaClient(baseURL: DemoServer.url, token: nil, transport: DemoTransport(now: { baseNow }))
        let tomorrow = GuideLayout.calendar.date(byAdding: .day, value: 1, to: today)!
        for day in [today, tomorrow] {
            let range = GuideLayout.broadcastRange(for: day)
            let guide = try JSONDecoder().decode(
                GuideResponse.self,
                from: try await client.send("api/programs?type=GR&from=\(range.from)&to=\(range.to)")
            )
            #expect(guide.services.count == 4)
            for service in guide.services {
                #expect(service.programs.first?.startAt == range.from)
                #expect(service.programs.last?.endAt == range.to)
                for (prev, next) in zip(service.programs, service.programs.dropFirst()) {
                    #expect(prev.endAt > prev.startAt)
                    #expect(prev.endAt == next.startAt)
                }
            }
        }
    }

    @Test func demoMutationsReturnUnavailableMessage() async throws {
        let (app, _, defaults, suite) = makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        app.startDemo()

        let guide = GuideModel(app: app)
        await guide.reload()
        let firstService = try #require(guide.guide?.services.first)
        let firstProgram = try #require(firstService.programs.first)
        let item = GuideProgramItem(service: firstService, program: firstProgram)

        #expect(await guide.reserve(item) == "デモでは使えません")
        #expect(await guide.cancel(item) == "デモでは使えません")

        let recordingsModel = RecordingsModel()
        await recordingsModel.start(app)
        defer { recordingsModel.stop() }
        let target = try #require(recordingsModel.recordings.first)
        #expect(await recordingsModel.delete(target) == "デモでは使えません")
        #expect(recordingsModel.recordings.count == 8)

        do {
            _ = try await app.post("api/services/101/record")
            Issue.record("デモでは失敗するはず")
        } catch let error as AppModel.APIError {
            #expect(error == .http(status: 400, message: "デモでは使えません"))
        }

        // 視聴位置の送信はエラーにせずそのまま通す
        let resume = try await app.post(
            "api/recordings/9001/resume",
            json: Data(#"{"at":10,"length":1800,"source":"encoded"}"#.utf8)
        )
        #expect(resume.isEmpty)
    }

    @Test func demoSSEStaysOpenWithoutReconnecting() async {
        let reconnects = Box(0)
        let authProblems = Box(0)
        let stream = EventStream(
            baseURL: DemoServer.url,
            token: nil,
            transport: DemoServer.sseTransport,
            sleep: { _ in },
            onEvent: { _ in },
            onReconnect: { reconnects.value += 1 },
            onAuthProblem: { _ in authProblems.value += 1 }
        )
        stream.start()
        try? await Task.sleep(for: .milliseconds(80))
        stream.stop()
        #expect(reconnects.value == 0)
        #expect(authProblems.value == 0)
    }

    @Test func demoVideoAndStreamLoaderLoopAndSeekCleanly() async throws {
        let video = try #require(DemoVideo.shared)
        let vTrack = try #require(video.tracks.first { $0.kind == .video })
        let aTrack = try #require(video.tracks.first { $0.kind == .audio })
        #expect(vTrack.codec.hasPrefix("avc1."))
        #expect(vTrack.height <= 720)
        #expect(aTrack.codec == "mp4a.40.2")

        // 周回をまたいでも先頭キーフレーム・PTS の連続性が保たれ、映像と音声がずれない
        let firstCycle = video.fragmentSamples(index: 0)
        let nextCycle = video.fragmentSamples(index: video.gopCount)
        let farCycle = video.fragmentSamples(index: 100)
        #expect(firstCycle.first { $0.kind == .video }?.pts == 0)
        #expect(firstCycle.first { $0.kind == .video }?.isKeyframe == true)
        #expect(nextCycle.first { $0.kind == .video }?.isKeyframe == true)

        let farV = try #require(farCycle.first { $0.kind == .video })
        let farA = try #require(farCycle.first { $0.kind == .audio })
        let vSec = Double(farV.pts) / Double(vTrack.timescale)
        let aSec = Double(farA.pts) / Double(aTrack.timescale)
        #expect(abs(vSec - aSec) < 0.0001)

        // StreamLoader 経由でシーク位置 (from=1140) から標本が届く
        let gotCodec = Box<String?>(nil)
        let firstVideoSec = Box<Double?>(nil)
        let url = URL(string: "milu-demo://demo/api/recordings/9002/stream?codec=h264&from=1140.000")!
        let loader = StreamLoader(url: url, mode: .buffered, pace: { 20 })
        loader.onResponse = { codec, _ in gotCodec.value = codec }
        loader.onSamples = { samples in
            if firstVideoSec.value == nil, let v = samples.first(where: { $0.kind == .video }) {
                firstVideoSec.value = Double(v.pts) / Double(vTrack.timescale)
            }
        }
        loader.start()
        for _ in 0..<50 where firstVideoSec.value == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        loader.cancel()

        #expect(gotCodec.value == "h264")
        let startSec = try #require(firstVideoSec.value)
        #expect(startSec <= 1140.0)
        #expect(startSec > 1138.5)
    }

    @Test func demoStreamRecordingCallsOnFinishExactlyOnce() async {
        // 残り約 5 GOP (初期送出 + タイマー tick で終端に達する経路) で onFinish(false) が 1 回だけ呼ばれること
        let finishResults = Box<[Bool]>([])
        let url = URL(string: "milu-demo://demo/api/recordings/9001/stream?codec=h264&from=1794.500")!
        let loader = StreamLoader(url: url, mode: .buffered, pace: { 0 })
        loader.onFinish = { empty in
            finishResults.value.append(empty)
        }
        loader.start()
        for _ in 0..<40 where finishResults.value.isEmpty {
            try? await Task.sleep(for: .milliseconds(30))
        }
        // 終端到達後にさらにタイマー周期ぶん待っても 2 回目が呼ばれないこと
        try? await Task.sleep(for: .milliseconds(350))
        loader.cancel()

        #expect(finishResults.value == [false])
    }

    @Test func makeForLaunchStartsInDemoOnlyWithUITestArgument() {
        let suite = "DemoTests-Launch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let savedURL = URL(string: "http://127.0.0.1:3000")!
        defaults.set(savedURL.absoluteString, forKey: "serverURL")
        let tokens = StubTokenStore()
        tokens.save("token-1", for: savedURL)

        // 引数が無いときは通常の保存先をそのまま読む
        let normal = AppModel.makeForLaunch(
            arguments: ["Milu"],
            keychain: tokens,
            defaults: defaults,
            startsEvents: false
        )
        #expect(!normal.isDemo)
        #expect(normal.server?.url == savedURL)
        #expect(normal.server?.token == "token-1")

        // -MiluUITestDemo があるときは通常の接続先 (serverURL) とトークンを上書きせずデモから始める
        let demo = AppModel.makeForLaunch(
            arguments: ["Milu", AppModel.uiTestDemoArgument],
            keychain: tokens,
            defaults: defaults,
            startsEvents: false
        )
        #expect(demo.isDemo)
        #expect(demo.phase == .connected)
        #expect(demo.server?.displayName == "デモ")
        #expect(defaults.string(forKey: "serverURL") == savedURL.absoluteString)
        #expect(tokens.load(for: savedURL) == "token-1")
    }
}
