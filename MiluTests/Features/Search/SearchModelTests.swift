import Foundation
import Testing

@testable import Milu

/// SearchModel (検索の状態) の単体テスト (3.5・D31)。
@Suite struct SearchModelTests {
    private var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private var ja: Locale { Locale(identifier: "ja_JP") }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func program(
        start: Date,
        end: Date,
        reservation: String? = nil
    ) -> SearchProgram {
        SearchProgram(
            id: 1,
            name: "星屑ステーション",
            serviceName: "ほしぞら放送",
            startAt: ms(start),
            endAt: ms(end),
            reservationState: reservation
        )
    }

    private func searchRecording(
        id: Int64 = 12,
        watch: String? = "watch/12",
        state: String = "available"
    ) -> SearchRecording {
        SearchRecording(
            id: id,
            name: "星屑ステーション #9",
            serviceName: "ほしぞら放送",
            startAt: ms(date(2026, 11, 14, 13)),
            state: state,
            watch: watch
        )
    }

    // MARK: 応答

    @Test func pathEncodesTheWordAndAsksForTen() {
        let path = SearchModel.path(query: "星 屑")
        #expect(path.hasPrefix("api/search?"))
        #expect(path.contains("limit=10"))
        #expect(!path.contains(" "))
        #expect(path.contains("q=%E6%98%9F%20%E5%B1%91"))
    }

    /// `+` は空白として読まれうるので %2B で送る
    @Test func pathEscapesPlus() {
        #expect(SearchModel.path(query: "a+b").contains("q=a%2Bb"))
    }

    @Test func oldResponsesAreDropped() {
        #expect(SearchModel.isCurrent(response: 3, current: 3, query: "a", currentQuery: "a"))
        #expect(!SearchModel.isCurrent(response: 2, current: 3, query: "a", currentQuery: "a"))
        // 同じ世代でも言葉が変わったら捨てる
        #expect(!SearchModel.isCurrent(response: 3, current: 3, query: "a", currentQuery: "ab"))
    }

    // MARK: 支度

    private let base = URL(string: "http://127.0.0.1:3000")!

    private nonisolated static func searchJSON(_ q: String, reservation: String? = nil) -> String {
        let state = reservation.map { #""\#($0)""# } ?? "null"
        return #"""
        { "q": "\#(q)",
          "programs": { "more": false, "rows": [
            { "id": 1, "name": "番組", "service_name": "局", "start_at": 1790000000000,
              "end_at": 1790001800000, "reservation_state": \#(state) }
          ] },
          "recordings": { "more": false, "rows": [
            { "id": 1, "name": "録画", "service_name": "局", "start_at": 1, "state": "available", "watch": "watch/1" }
          ] } }
        """#
    }

    private nonisolated static let emptySearchJSON = #"""
    { "q": "a", "programs": { "more": false, "rows": [] }, "recordings": { "more": false, "rows": [] } }
    """#

    private nonisolated static func recordingJSON(_ id: Int64) -> String {
        #"""
        { "id": \#(id), "title": "録画\#(id)", "name": "録画\#(id)", "serviceId": 1, "serviceName": "局",
          "startAt": 1, "endAt": 2, "durationMs": 60000, "resumeMs": 1000, "watchedAt": null,
          "recording": false, "chase": null, "cmReliable": true, "poster": null,
          "files": [], "audio": "api/recordings/\#(id)/file?audio=only", "audios": [] }
        """#
    }

    private func fixture(
        _ transport: StubTransport,
        url: URL? = nil,
        debounce: Duration = .zero
    ) -> (SearchModel, AppModel) {
        let name = "SearchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set((url ?? base).absoluteString, forKey: "serverURL")
        let app = AppModel(
            service: ConnectionService(transport: transport),
            keychain: StubTokenStore(),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (SearchModel(debounce: debounce), app)
    }

    private func makeSearchTransport(
        services: String = "[]",
        servicesStatus: Int = 200
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, servicesStatus, services)
            }
            if path.hasSuffix("api/search") {
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
    }

    private nonisolated static func query(of request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value ?? ""
    }

    private nonisolated static func offset(of request: URLRequest) -> Int {
        Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "offset" }?.value ?? "") ?? 0
    }

    private func searchCount(_ transport: StubTransport) -> Int {
        transport.requests.filter { $0.url?.path.hasSuffix("api/search") == true }.count
    }

    private func recordingsCount(_ transport: StubTransport) -> Int {
        transport.requests.filter { $0.url?.path.hasSuffix("api/recordings") == true }.count
    }

    /// 応答を保留できる合図。合図が来ないまま上限を過ぎたら、止まらずに失敗として記録して進む
    private actor Gate {
        private var open = false
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func wait(timeout: Duration = .seconds(5)) async {
            guard !open else { return }
            let id = UUID()
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
            await withCheckedContinuation { waiters[id] = $0 }
        }

        func signal() {
            open = true
            for waiter in waiters.values { waiter.resume() }
            waiters = [:]
        }

        private func expire(_ id: UUID) {
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            Issue.record("合図が来ないまま上限を過ぎた")
            waiter.resume()
        }
    }

    // MARK: 経路 (T 必須 1・2)

    /// A を表示 → 更新を起こしてその GET を保留 → B を入力 → A の応答を返す。
    /// A の成功・失敗とも、A の処理が終わってから検査する
    @MainActor @Test(arguments: [true, false])
    func aHeldRefreshDoesNotOverwriteTheNewWord(succeeds: Bool) async {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let q = Self.query(of: request)
                let index = searches.value
                searches.value = index + 1
                // 1 回目は A の表示。2 回目 (更新) を保留する
                if q == "a", index == 1 {
                    await started.signal()
                    await release.wait()
                    return succeeds
                        ? reply(request, 200, Self.searchJSON("a"))
                        : reply(request, 500, #"{"message":"だめ"}"#)
                }
                return reply(request, 200, Self.searchJSON(q))
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)

        // A を表示
        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.results?.q == "a")

        // 更新を起こして保留
        let held = Task { await model.refresh() }
        await started.wait()

        // B を入力して反映
        model.setQuery("b")
        _ = await model.refresh()
        #expect(model.results?.q == "b")

        await release.signal()
        _ = await held.value
        // 遅れて終わった A は成功でも失敗でも当てない
        #expect(model.results?.q == "b")
        #expect(model.load == .ready)
    }

    @MainActor @Test func changingTheWordDropsTheOldResults() async {
        let transport = makeSearchTransport()
        let (model, app) = fixture(transport)
        await model.start(app)

        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.results != nil)

        model.setQuery("ab")
        // 前の言葉の結果を出したままにしない (T 必須 1)
        #expect(model.results == nil)
        #expect(model.load == .loading)
    }

    // MARK: 録画だけを出す (D32)

    @MainActor @Test func recordingResultsAreOnlyTheRecordings() async {
        let (model, app) = fixture(makeSearchTransport())
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.results?.programs.rows.count == 1)
        #expect(model.recordingResults?.rows.map(\.id) == [1])
    }

    @MainActor @Test func programsOnlyIsNoRecording() async {
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/search") {
                return reply(request, 200, #"""
                { "q": "a",
                  "programs": { "more": false, "rows": [
                    { "id": 1, "name": "番組", "service_name": "局", "start_at": 1, "end_at": 2, "reservation_state": null }
                  ] },
                  "recordings": { "more": false, "rows": [] } }
                """#)
            }
            return reply(request, 200, "[]")
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        // 番組は当たっているが、録画としては一致なし (空の節。nil ではない)
        #expect(model.load == .ready)
        #expect(model.recordingResults?.rows.isEmpty == true)
    }

    @MainActor @Test func clearingTheWordClearsTheRecordingResults() async {
        let (model, app) = fixture(makeSearchTransport())
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.recordingResults != nil)
        model.setQuery("")
        #expect(model.recordingResults == nil)
    }

    /// 観る画面で削除して戻ったら、その行は読み直しを待たずに結果から外す (D32)
    @MainActor @Test func closingAfterADeleteRemovesTheRecording() async {
        let (model, app) = fixture(makeSearchTransport())
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.recordingResults?.rows.map(\.id) == [1])

        model.closeOpen(deletedID: 1)
        #expect(model.recordingResults?.rows.isEmpty == true)
        // 番組は残っているので「一致する録画はありません」の側 (nil ではない)
        #expect(model.load == .ready)
    }

    /// 削除で閉じたとき、削除より前に送った GET が遅れて返っても、削除した行を戻さない
    @MainActor @Test func closingAfterADeleteDropsThePendingGet() async {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let deleted = Box(false)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                // 送った時点で削除前なら、応答に削除された行を (古い応答として) 残す
                let hadRow = !deleted.value
                if index == 1 {
                    await started.signal()
                    await release.wait()
                }
                return reply(
                    request,
                    200,
                    hadRow ? Self.searchJSON(Self.query(of: request)) : Self.emptySearchJSON
                )
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        #expect(model.recordingResults?.rows.map(\.id) == [1])

        // 削除より前に送った更新を保留する
        let held = Task { await model.refresh() }
        await started.wait()

        // 観る画面で削除して閉じ、そのあと読み直す (削除した行は含まれない)
        deleted.value = true
        model.closeOpen(deletedID: 1)
        let readAgain = Task { await model.refresh() }
        try? await Task.sleep(for: .milliseconds(50))

        // 保留していた古い応答 (削除した行を含む) を返す
        await release.signal()
        _ = await readAgain.value
        _ = await held.value
        #expect(model.recordingResults?.rows.isEmpty == true)
    }

    @MainActor @Test func refreshDuringTheInputSendsOnce() async {
        let transport = makeSearchTransport()
        let (model, app) = fixture(transport)
        await model.start(app)

        let input = model.setQuery("a")
        _ = await model.refresh()
        _ = await input?.value
        // 入力と更新の両方が終わってから、送った数を見る (C 必須 2)
        #expect(searchCount(transport) == 1)
    }

    /// 観る画面を閉じたあとの更新が遅れて呼ばれても、そのあとに打った言葉の待ちを取り消さない
    @MainActor @Test func aLateRefreshKeepsThePendingInput() async {
        let transport = makeSearchTransport()
        let (model, app) = fixture(transport, debounce: .milliseconds(200))
        await model.start(app)

        let input = model.setQuery("ab")
        let applied = await model.refresh()
        #expect(input?.isCancelled == false)
        // 更新は入力が送り終わるのを待つだけで、自分では送らない
        #expect(applied)
        #expect(searchCount(transport) == 1)
        #expect(model.results?.q == "ab")
    }

    /// 更新が入力の GET を待っている間に、もう 1 つの更新が来ても送り直さず、どちらも結果を得る
    @MainActor @Test func aSecondRefreshJoinsTheInFlightGet() async {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                // 最初 (入力) の GET を保留する
                if index == 0 {
                    await started.signal()
                    await release.wait()
                }
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)

        model.setQuery("a")
        let first = Task { await model.refresh() }
        await started.wait()
        let second = Task { await model.refresh() }
        // 2 回目が合流の判断をするまで待つ (送り直していれば数が増える)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(searchCount(transport) == 1)

        await release.signal()
        #expect(await first.value)
        #expect(await second.value)
        #expect(searchCount(transport) == 1)
        #expect(model.results?.q == "a")
    }

    /// 言葉を消したら、保留していた GET は当たらない
    @MainActor @Test func clearingTheWordCancelsThePendingSend() async {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                if index == 1 {
                    await started.signal()
                    await release.wait()
                }
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()

        let held = Task { await model.refresh() }
        await started.wait()
        model.setQuery("")
        await release.signal()
        _ = await held.value
        #expect(model.results == nil)
        #expect(model.load == .idle)
    }

    /// stop したら、保留していた GET は当たらない
    @MainActor @Test func stopCancelsThePendingSend() async {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                if index == 1 {
                    await started.signal()
                    await release.wait()
                    // 当たったら分かるように別の語の応答を返す
                    return reply(request, 200, Self.searchJSON("stale"))
                }
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()

        let held = Task { await model.refresh() }
        await started.wait()
        model.stop()
        await release.signal()
        _ = await held.value
        #expect(model.results?.q == "a")
    }

    // MARK: 録画を一覧から探す (C 必須 1・2)

    private func recordingsTransport(
        pages: [[String]],
        fail: Bool = false
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/recordings") {
                if fail {
                    return reply(request, 500, #"{"message":"だめ"}"#)
                }
                let index = Self.offset(of: request) / SearchModel.recordingsPageSize
                let rows = pages.indices.contains(index) ? pages[index] : []
                return reply(request, 200, "[" + rows.joined(separator: ",") + "]")
            }
            return reply(request, 404)
        }
    }

    /// 最初の録画の一覧だけを保留する
    private func holdingRecordingsTransport(started: Gate, release: Gate) -> StubTransport {
        let requests = Box(0)
        return StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/recordings") {
                let index = requests.value
                requests.value = index + 1
                if index == 0 {
                    await started.signal()
                    await release.wait()
                }
                return reply(request, 200, "[" + Self.recordingJSON(12) + "]")
            }
            if path.hasSuffix("api/search") {
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
    }

    @MainActor
    private func openedRecording(_ model: SearchModel) -> Recording? {
        model.openRequest?.session.recording
    }

    @MainActor @Test func findsTheRecordingOnTheFirstPage() async {
        let transport = recordingsTransport(pages: [[Self.recordingJSON(10), Self.recordingJSON(12)]])
        let (model, app) = fixture(transport)
        await model.start(app)
        await model.openRecording(id: 12)
        let recording = openedRecording(model)
        #expect(recording?.id == 12)
        // 一覧の値 (続き・尺・局) をそのまま使える
        #expect(recording?.resumeMs == 1000)
        #expect(recording?.durationMs == 60000)
    }

    @MainActor @Test func findsTheRecordingOnTheSecondPageEvenIfAPageHasAnUnreadableRow() async {
        var first = (1...99).map { Self.recordingJSON(Int64($0)) }
        first.append(#"{"id": 9999}"#) // 読めない要素。数は 100 のまま
        let transport = recordingsTransport(pages: [first, [Self.recordingJSON(555)]])
        let (model, app) = fixture(transport)
        await model.start(app)
        await model.openRecording(id: 555)
        let recording = openedRecording(model)
        #expect(recording?.id == 555)
        #expect(recordingsCount(transport) == 2)
    }

    @MainActor @Test func anEmptyPageStopsTheSearch() async {
        let transport = recordingsTransport(pages: [[]])
        let (model, app) = fixture(transport)
        await model.start(app)
        await model.openRecording(id: 12)
        #expect(model.openRequest == nil)
        #expect(model.openError == "この録画を開けませんでした。")
        #expect(recordingsCount(transport) == 1)
    }

    @MainActor @Test func missingRecordingIsMissing() async {
        let transport = recordingsTransport(pages: [[Self.recordingJSON(10), Self.recordingJSON(12)]])
        let (model, app) = fixture(transport)
        await model.start(app)
        await model.openRecording(id: 99)
        #expect(model.openRequest == nil)
        #expect(model.openError == "この録画を開けませんでした。")
    }

    @MainActor @Test func failedRecordingListIsMissing() async {
        let transport = recordingsTransport(pages: [[Self.recordingJSON(12)]], fail: true)
        let (model, app) = fixture(transport)
        await model.start(app)
        await model.openRecording(id: 12)
        #expect(model.openRequest == nil)
        #expect(model.openError == "この録画を開けませんでした。")
    }

    @MainActor @Test func aNewOpenCancelsTheOldOne() async {
        let started = Gate()
        let release = Gate()
        let transport = holdingRecordingsTransport(started: started, release: release)
        let (model, app) = fixture(transport)
        await model.start(app)

        let first = Task { await model.openRecording(id: 12) }
        await started.wait()
        await model.openRecording(id: 12)
        #expect(openedRecording(model)?.id == 12)
        await release.signal()
        await first.value
        // 取り消された探索は状態を書き換えない
        #expect(openedRecording(model)?.id == 12)
        #expect(model.openError == nil)
    }

    /// 観る画面を閉じたあとの更新が遅れて呼ばれても、そのあとに始めた探索を取り消さない
    @MainActor @Test func aLateRefreshKeepsTheOpen() async {
        let started = Gate()
        let release = Gate()
        let transport = holdingRecordingsTransport(started: started, release: release)
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()

        let open = Task { await model.openRecording(id: 12) }
        await started.wait()
        _ = await model.refresh()
        await release.signal()
        await open.value
        #expect(openedRecording(model)?.id == 12)
        #expect(model.openError == nil)
    }

    @MainActor @Test func stopCancelsTheOpen() async {
        let started = Gate()
        let release = Gate()
        let transport = holdingRecordingsTransport(started: started, release: release)
        let (model, app) = fixture(transport)
        await model.start(app)

        let first = Task { await model.openRecording(id: 12) }
        await started.wait()
        model.stop()
        await release.signal()
        await first.value
        #expect(model.openRequest == nil)
        #expect(model.openError == nil)
    }

    @MainActor @Test func changingTheWordCancelsTheOpen() async {
        let started = Gate()
        let release = Gate()
        let transport = holdingRecordingsTransport(started: started, release: release)
        let (model, app) = fixture(transport)
        await model.start(app)

        let first = Task { await model.openRecording(id: 12) }
        await started.wait()
        model.setQuery("b")
        await release.signal()
        await first.value
        #expect(model.openRequest == nil)
        #expect(model.openError == nil)
    }

    @MainActor @Test func changingTheServerCancelsTheOpen() async {
        let started = Gate()
        let release = Gate()
        let transport = holdingRecordingsTransport(started: started, release: release)
        let (model, app) = fixture(transport)
        await model.start(app)

        let first = Task { await model.openRecording(id: 12) }
        await started.wait()

        // 接続先を替える。探索は取り消され、古い URL の結果は反映しない
        let (_, other) = fixture(transport, url: URL(string: "http://127.0.0.1:3999")!)
        await model.start(other)
        await release.signal()
        await first.value
        #expect(model.openRequest == nil)
        #expect(model.openError == nil)
    }

    @MainActor @Test func applyingAfterInvalidationDoesNothing() async throws {
        let transport = makeSearchTransport()
        let (model, app) = fixture(transport)
        await model.start(app)
        let recording = try JSONDecoder().decode(Recording.self, from: Data(Self.recordingJSON(12).utf8))

        // 探索の世代が進んだあとに古い結果を当てようとしても何もしない
        model.applyOpenResult(.found(recording), generation: -1, from: base)
        #expect(model.openRequest == nil)
        model.applyOpenResult(.missing, generation: -1, from: base)
        #expect(model.openError == nil)
    }

    // MARK: 予約・取消のあとの巻き戻り (C 必須 3)

    @MainActor @Test func aHeldSearchDoesNotUndoAReservation() async throws {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                if index == 1 {
                    await started.signal()
                    await release.wait()
                }
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            if path.hasSuffix("/record") {
                return reply(request, 200, #"{"reserved":true,"state":"scheduled"}"#)
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)

        model.setQuery("a")
        _ = await model.refresh()
        let item = try #require(model.program(id: 1))
        #expect(model.results?.programs.rows.first?.reservationState == nil)

        let held = Task { await model.refresh() }
        await started.wait()
        let message = await model.reserve(item)
        #expect(message == nil)
        #expect(model.results?.programs.rows.first?.reservationState == "scheduled")

        await release.signal()
        _ = await held.value
        // 予約より前に送った検索が遅れて返っても巻き戻さない
        #expect(model.results?.programs.rows.first?.reservationState == "scheduled")
        #expect(model.load == .ready)
    }

    /// 予約の確認は、POST より前に送った GET を流用せず、POST の後で始まった GET で確かめる
    @MainActor @Test func reserveConfirmsWithAGetStartedAfterThePost() async throws {
        let started = Gate()
        let release = Gate()
        let searches = Box(0)
        let posted = Box(false)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("/record") {
                posted.value = true
                return reply(request, 200, "not json")
            }
            if path.hasSuffix("api/search") {
                let index = searches.value
                searches.value = index + 1
                // 2 回目 (予約より前の更新) を保留する。応答は送った時点の予約の有無で決まる
                let reservation = posted.value ? "scheduled" : nil
                if index == 1 {
                    await started.signal()
                    await release.wait()
                }
                return reply(
                    request,
                    200,
                    Self.searchJSON(Self.query(of: request), reservation: reservation)
                )
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        let item = try #require(model.program(id: 1))

        // 予約より前に更新を送り、その GET を保留しておく
        let held = Task { await model.refresh() }
        await started.wait()

        let message = await model.reserve(item)
        // 保留した GET ではなく、POST の後に始まった GET で確かめた
        #expect(message == nil)
        #expect(model.results?.programs.rows.first?.reservationState == "scheduled")

        await release.signal()
        _ = await held.value
        #expect(model.results?.programs.rows.first?.reservationState == "scheduled")
    }

    @MainActor @Test func unreadableReservationBodyAndFailedReloadIsReported() async {
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("/record") {
                return reply(request, 200, "not json")
            }
            if path.hasSuffix("api/search") {
                return reply(request, 500, #"{"message":"だめ"}"#)
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()

        let item = model.programItem(program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)))
        let message = await model.reserve(item)
        #expect(message == "予約の状態を確かめられませんでした。")
    }

    @MainActor @Test func unreadableBodyAndReloadWithoutTheProgramIsReported() async throws {
        let posted = Box(false)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("/record") {
                posted.value = true
                return reply(request, 200, "not json")
            }
            if path.hasSuffix("api/search") {
                if posted.value { return reply(request, 200, Self.emptySearchJSON) }
                return reply(request, 200, Self.searchJSON(Self.query(of: request)))
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        let item = try #require(model.program(id: 1))

        let message = await model.reserve(item)
        // 読み直しは効いたが、その番組の行が無いので確かめられない
        #expect(message == "予約の状態を確かめられませんでした。")
    }

    @MainActor @Test func unreadableBodyAndReloadConfirmingTheProgramIsOK() async throws {
        let posted = Box(false)
        let transport = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, "[]")
            }
            if path.hasSuffix("/record") {
                posted.value = true
                return reply(request, 200, "not json")
            }
            if path.hasSuffix("api/search") {
                let reservation = posted.value ? "scheduled" : nil
                return reply(
                    request,
                    200,
                    Self.searchJSON(Self.query(of: request), reservation: reservation)
                )
            }
            return reply(request, 404)
        }
        let (model, app) = fixture(transport)
        await model.start(app)
        model.setQuery("a")
        _ = await model.refresh()
        let item = try #require(model.program(id: 1))

        let message = await model.reserve(item)
        #expect(message == nil)
        #expect(model.results?.programs.rows.first?.reservationState == "scheduled")
    }

    // MARK: 局の解決 (C 必須 6)

    private func servicesJSON(_ names: [String]) -> String {
        let items = names.enumerated().map { index, name in
            #"{"id": \#(index + 1), "type": "GR", "name": "\#(name)", "remoteControlKey": \#(index + 1), "logo": null, "live": "api/services/\#(index + 1)/live", "airing": true, "video": true, "now": null}"#
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    @MainActor @Test func uniqueServiceNameGivesTheId() async {
        let transport = makeSearchTransport(services: servicesJSON(["ほしぞら放送", "あおばTV"]))
        let (model, app) = fixture(transport)
        await model.start(app)
        let item = model.programItem(program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)))
        #expect(item.serviceID == 1)
    }

    @MainActor @Test func duplicateServiceNameIsNotResolved() async {
        let transport = makeSearchTransport(services: servicesJSON(["ほしぞら放送", "ほしぞら放送"]))
        let (model, app) = fixture(transport)
        await model.start(app)
        let item = model.programItem(program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)))
        // 先頭に寄せない
        #expect(item.serviceID == nil)
    }

    @MainActor @Test func serviceListMissingIsNotResolved() async {
        let transport = makeSearchTransport(services: "[]")
        let (model, app) = fixture(transport)
        await model.start(app)
        let item = model.programItem(program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)))
        #expect(item.serviceID == nil)
    }

    @MainActor @Test func failedServiceListIsNotResolved() async {
        let transport = makeSearchTransport(servicesStatus: 500)
        let (model, app) = fixture(transport)
        await model.start(app)
        let item = model.programItem(program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)))
        #expect(item.serviceID == nil)
    }

    // MARK: 行の文言

    @Test func programRowShowsTimeDayAndReservation() {
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 21, 13), end: date(2026, 11, 21, 14), reservation: "scheduled"),
            now: date(2026, 11, 25, 12),
            calendar: tokyo,
            locale: ja
        )
        #expect(text.time == "13:00")
        #expect(text.day == "11/21 (土)")
        #expect(text.state == .reserved)
        #expect(text.state?.text(locale: ja) == "予約済み")
        #expect(text.state?.text(locale: Locale(identifier: "en_US")) == "Scheduled")
    }

    @Test func programRowUsesTodayForToday() {
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19)),
            now: date(2026, 11, 25, 12),
            calendar: tokyo,
            locale: ja
        )
        #expect(text.time == "18:00")
        #expect(text.day == "今日")
        #expect(text.state == nil)
    }

    @Test func programRowIsOnAirExactlyFromTheStart() {
        let start = date(2026, 11, 25, 12)
        let text = SearchModel.programRowText(
            program(start: start, end: date(2026, 11, 25, 13)),
            now: start,
            calendar: tokyo,
            locale: ja
        )
        #expect(text.state == .onAir)
    }

    @Test func programRowIsNotOnAirExactlyAtTheEnd() {
        let end = date(2026, 11, 25, 13)
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 25, 12), end: end),
            now: end,
            calendar: tokyo,
            locale: ja
        )
        #expect(text.state == nil)

        let reserved = SearchModel.programRowText(
            program(start: date(2026, 11, 25, 12), end: end, reservation: "scheduled"),
            now: end,
            calendar: tokyo,
            locale: ja
        )
        #expect(reserved.state == .reserved)
    }

    @Test func programRowShowsOnAirBeforeReservation() {
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 25, 11, 30), end: date(2026, 11, 25, 12, 30), reservation: "recording"),
            now: date(2026, 11, 25, 12),
            calendar: tokyo,
            locale: ja
        )
        #expect(text.state == .onAir)
        #expect(text.state?.text(locale: ja) == "● 放送中")
    }

    @Test func programRowShowsRecordingOutsideTheAirtime() {
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 25, 18), end: date(2026, 11, 25, 19), reservation: "recording"),
            now: date(2026, 11, 25, 12),
            calendar: tokyo,
            locale: ja
        )
        #expect(text.state == .reserved)
    }

    @Test func programRowIgnoresOtherReservationStates() {
        let text = SearchModel.programRowText(
            program(start: date(2026, 11, 21, 13), end: date(2026, 11, 21, 14), reservation: "conflict"),
            now: date(2026, 11, 25, 12),
            calendar: tokyo,
            locale: ja
        )
        #expect(text.state == nil)
    }

    @Test func recordingSubtitleShowsDateAndTime() {
        let recording = searchRecording()
        #expect(SearchModel.recordingSubtitle(recording, calendar: tokyo, locale: ja) == "11/14 (土) 13:00 · ほしぞら放送")
        #expect(SearchModel.tvRecordingSubtitle(recording, calendar: tokyo, locale: ja) == "ほしぞら放送 · 11/14 (土) 13:00")
        #expect(SearchModel.recordingThird(recording, locale: ja) == nil)
    }

    @Test func unplayableRecordingIsMarked() {
        let recording = searchRecording(watch: nil, state: "failed")
        #expect(SearchModel.recordingSubtitle(recording, calendar: tokyo, locale: ja).hasPrefix("再生できません · "))
        #expect(SearchModel.tvRecordingSubtitle(recording, calendar: tokyo, locale: ja).hasPrefix("再生できません · "))
        #expect(!recording.playable)
    }

    @Test func recordingRowShowsTheRecordingBadge() {
        #expect(SearchModel.recordingThird(searchRecording(state: "recording"), locale: ja) == "● 録画中")
    }
}
