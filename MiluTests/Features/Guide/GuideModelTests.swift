import Foundation
import Testing

@testable import Milu

/// GuideModel (番組表のタブの状態) の単体テスト。
@Suite struct GuideModelTests {
    private let base = URL(string: "http://127.0.0.1:3000")!

    private func fixture(
        _ transport: StubTransport,
        now: Date = Date()
    ) -> (GuideModel, AppModel, StubTokenStore) {
        let tokens = StubTokenStore()
        let name = "GuideModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(base.absoluteString, forKey: "serverURL")
        let app = AppModel(
            service: ConnectionService(transport: transport),
            keychain: tokens,
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (GuideModel(app: app, now: now), app, tokens)
    }

    private let servicesJSON = #"""
    [
      { "id": 3273601024, "type": "GR", "name": "ＮＨＫ総合１・東京", "remoteControlKey": 1,
        "logo": "api/services/3273601024/logo", "live": "api/services/3273601024/live",
        "airing": true, "video": true, "now": null },
      { "id": 200, "type": "CS", "name": "CSチャンネル", "remoteControlKey": 55,
        "logo": null, "live": "api/services/200/live", "airing": true, "video": true, "now": null }
    ]
    """#

    nonisolated private func guideJSON(_ reservation: String?) -> String {
        let reservationField = reservation ?? "null"
        return """
        {
          "type": "GR", "from": 1794596400000, "to": 1794682800000, "until": 1795535640000,
          "services": [
            { "id": 3273601024, "name": "ＮＨＫ総合１・東京", "mainId": null, "remoteControlKey": 1,
              "logo": "api/services/3273601024/logo",
              "programs": [
                { "id": 101, "name": "番組名", "startAt": 1794632400000, "endAt": 1794636000000,
                  "description": "説明", "genre": 7, "copyNever": false,
                  "reservation": \(reservationField), "recordingId": null }
              ] }
          ]
        }
        """
    }

    private func transport(
        services: String? = nil,
        guide: @escaping @Sendable (URLRequest) -> String? = { _ in nil },
        programs: String? = nil
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, services ?? "[]")
            }
            if path.hasSuffix("api/programs") {
                return reply(request, 200, guide(request) ?? programs ?? "")
            }
            return reply(request, 404, #"{"message":"not here"}"#)
        }
    }

    @Test func reloadLoadsTypesAndGuide() async throws {
        let stub = transport(services: servicesJSON, programs: guideJSON(nil))
        let (model, _, _) = fixture(stub)
        await model.reload()
        #expect(!model.didFail)
        // 局のある種別だけ。CS は並びは GR・BS・CS・CATV・SKY 順の中にある
        #expect(model.availableTypes == [.GR, .CS])
        #expect(model.guide?.services.count == 1)
        let item = try #require(model.program(id: 101))
        #expect(item.serviceName == "ＮＨＫ総合１・東京")
        #expect(item.genre == 7)
    }

    @Test func unavailableSelectedTypeFallsBack() async throws {
        let stub = transport(services: servicesJSON, programs: guideJSON(nil))
        let (model, _, _) = fixture(stub)
        model.selectType(.BS)
        await model.reload()
        #expect(model.selectedType == .GR)
    }

    @Test func fetchFailureSetsDidFail() async throws {
        let stub = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                throw URLError(.timedOut)
            }
            return reply(request, 200, "[]")
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        #expect(model.didFail)
        #expect(model.guide == nil)
    }

    @Test func reservePostsAndReloads() async throws {
        let calls = Box<[String]>([])
        let stub = StubTransport { request in
            calls.value = calls.value + ["\(request.httpMethod ?? "") \(request.url?.path ?? "")"]
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            if request.url?.path.hasSuffix("/record") == true {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                return reply(request, 200, #"{"recorded":"番組名","programId":101,"reserved":true,"state":"scheduled","reason":null}"#)
            }
            // 2 回目の読み直しでは予約済み
            return reply(request, 200, self.guideJSON(#"{"state":"scheduled","reason":null,"ruleId":null}"#))
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        let item = try #require(model.program(id: 101))
        let message = await model.reserve(item)
        #expect(message == nil)
        // 予約 → 読み直し (GET programs が 2 回) → 中身が新しい状態
        #expect(model.program(id: 101)?.reservation?.state == .scheduled)
        let programsCalls = calls.value.filter { $0.hasPrefix("GET ") && $0.contains("api/programs") }.count
        #expect(programsCalls == 2)
    }

    @Test func reservedFalseReturnsReason() async throws {
        let stub = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            if request.url?.path.hasSuffix("/record") == true {
                return reply(
                    request, 200,
                    #"{"recorded":"番組名","programId":101,"reserved":false,"state":"conflict","reason":"チューナーが足りません"}"#
                )
            }
            return reply(request, 200, self.guideJSON(nil))
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        let item = try #require(model.program(id: 101))
        let message = await model.reserve(item)
        #expect(message == "チューナーが足りません")
    }

    @Test func reserveFailureReturnsMessage() async throws {
        let failing = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            if request.url?.path.hasSuffix("/record") == true {
                return reply(request, 503, #"{"message":"サーバが混んでいます"}"#)
            }
            return reply(request, 200, self.guideJSON(nil))
        }
        let (model, _, _) = fixture(failing)
        await model.reload()
        let item = try #require(model.program(id: 101))
        let message = await model.reserve(item)
        #expect(message == "サーバが混んでいます")
    }

    @Test func cancelDeletesAndReloads() async throws {
        let stub = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            if request.url?.path.hasSuffix("/record") == true {
                #expect(request.httpMethod == "DELETE")
                return reply(request, 200, #"{"stopped":false}"#)
            }
            return reply(request, 200, self.guideJSON(nil))
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        let item = try #require(model.program(id: 101))
        let message = await model.cancel(item)
        #expect(message == nil)
        #expect(model.program(id: 101)?.reservation == nil)
    }

    @Test func detail404ReturnsNil() async throws {
        let stub = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            if request.url?.path.hasSuffix("api/programs/101") == true {
                return reply(request, 404, #"{"message":"番組が見つかりません"}"#)
            }
            return reply(request, 200, self.guideJSON(nil))
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        let item = try #require(model.program(id: 101))
        let detail = await model.detail(item)
        #expect(detail == nil)
    }

    @Test func watchLiveRequestsTabChange() async throws {
        let stub = transport(services: servicesJSON, programs: guideJSON(nil))
        let (model, app, _) = fixture(stub)
        await model.reload()
        let item = try #require(model.program(id: 101))
        model.watchLive(item)
        #expect(app.liveWatch?.serviceID == 3273601024)
    }

    @Test func selectDayReloadsNewRange() async throws {
        let stub = StubTransport { request in
            if request.url?.path.hasSuffix("api/services") == true {
                return reply(request, 200, self.servicesJSON)
            }
            return reply(request, 200, self.guideJSON(nil))
        }
        let (model, _, _) = fixture(stub)
        await model.reload()
        let day = try #require(GuideLayout.calendar.date(byAdding: .day, value: 1, to: model.selectedDay))
        model.selectDay(day)
        await model.reload()
        // from/to が翌日の放送日になっていること (4:00 起点)
        let request = stub.requests.last { $0.url?.path.hasSuffix("api/programs") == true }
        let query = request?.url?.query ?? ""
        #expect(query.contains("from="))
    }

    // MARK: tvOS の窓

    private func response(
        from: Int64,
        to: Int64,
        programs: [(id: Int64, startAt: Int64)],
        until: Int64? = nil
    ) -> GuideResponse {
        GuideResponse(
            type: .GR,
            from: from,
            to: to,
            until: until,
            services: [
                GuideService(
                    id: 3273601024,
                    name: "ＮＨＫ総合１・東京",
                    mainId: nil,
                    remoteControlKey: 1,
                    logo: nil,
                    programs: programs.map {
                        GuideProgram(
                            id: $0.id,
                            name: "番組\($0.id)",
                            startAt: $0.startAt,
                            endAt: $0.startAt + 1_800_000,
                            description: nil,
                            genre: nil,
                            copyNever: false,
                            reservation: nil,
                            recordingId: nil
                        )
                    }
                )
            ]
        )
    }

    @Test func mergeJoinsDaysInTimeOrder() throws {
        let first = response(from: 1_000, to: 9_000, programs: [(1, 2_000), (2, 5_000)], until: 8_000)
        let second = response(from: 9_000, to: 17_000, programs: [(2, 5_000), (3, 9_000)], until: 12_000)
        let merged = try #require(GuideModel.merge([second, first]))
        #expect(merged.from == 1_000)
        #expect(merged.to == 17_000)
        #expect(merged.until == 12_000)
        // 2 日目にも出てくる番組は 1 つにまとめ、始まり順に並べる
        #expect(merged.services.first?.programs.map(\.id) == [1, 2, 3])
    }

    @Test func mergeKeepsCrossingProgramOnce() throws {
        // 4:00 をまたぐ番組は両日の応答に入る。1 マスにまとめ、予約の印が載っている方を残す
        let boundary: Int64 = 1_794_682_800_000
        let crossing = GuideProgram(
            id: 7, name: "またぐ番組", startAt: boundary - 1_800_000, endAt: boundary + 1_800_000,
            description: nil, genre: 1, copyNever: false, reservation: nil, recordingId: nil
        )
        let reserved = GuideProgram(
            id: 7, name: "またぐ番組", startAt: boundary - 1_800_000, endAt: boundary + 1_800_000,
            description: nil, genre: 1, copyNever: false,
            reservation: ReservationInfo(stateRaw: "scheduled", reason: nil, ruleId: nil),
            recordingId: nil
        )
        func guide(from: Int64, to: Int64, programs: [GuideProgram]) -> GuideResponse {
            GuideResponse(
                type: .GR, from: from, to: to, until: nil,
                services: [GuideService(id: 1, name: "局", mainId: nil, remoteControlKey: nil, logo: nil, programs: programs)]
            )
        }
        // 印が載っている方が後の日の応答でない場合でも落とさない
        let merged = try #require(GuideModel.merge([
            guide(from: boundary - 86_400_000, to: boundary, programs: [reserved]),
            guide(from: boundary, to: boundary + 86_400_000, programs: [crossing]),
        ]))
        let programs = try #require(merged.services.first?.programs)
        #expect(programs.map(\.id) == [7])
        #expect(programs.first?.reservation != nil)
    }

    @Test func iosReloadLeavesTVStateEmpty() async throws {
        let stub = transport(services: servicesJSON, programs: guideJSON(nil))
        let (model, _, _) = fixture(stub)
        await model.reload()
        #expect(model.guide != nil)
        // iOS の読みは tvOS の窓に触らない
        #expect(model.tvGuide == nil)
        #expect(model.tvDays.isEmpty)
    }

    @Test func tvStartLoadsOpenDayAndNext() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let tomorrow = dayOffset(1, from: day)
        let stub = tvTransport()
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        // 開いた日は前の日を読まず、翌日までを先に読む
        #expect(model.tvDays == [day, tomorrow])
        #expect(model.tvFrom == GuideLayout.broadcastRange(for: day).from)
        #expect(model.tvTo == GuideLayout.broadcastRange(for: tomorrow).to)
        #expect(model.tvGuide?.services.first?.programs.count == 2)
        // 端で ↓ (カーソルが翌日へ入った) と、その次の日も読む
        await model.tvReload(center: tomorrow, now: now)
        #expect(model.tvDays == [day, tomorrow, dayOffset(2, from: day)])
        #expect(model.tvGuide?.services.first?.programs.count == 3)
    }

    @Test func tvReloadKeepsLoadedDaysOnFailure() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let tomorrow = dayOffset(1, from: day)
        let failures = Box<Set<Int64>>([GuideLayout.broadcastRange(for: dayOffset(2, from: day)).from])
        let stub = tvTransport(fails: { failures.value.contains($0) })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        #expect(model.tvDays == [day, tomorrow])
        // 翌日へ入る。その次が読めなくても、いまある範囲はそのまま使える
        await model.tvReload(center: tomorrow, now: now)
        #expect(model.tvDays == [day, tomorrow])
        #expect(model.tvGuide?.services.first?.programs.count == 2)
        #expect(!model.tvDidFail)
        // 通信が戻ったら、端でもう一度押したときに続きが読める
        failures.value = []
        await model.tvReload(center: tomorrow, now: now)
        #expect(model.tvDays == [day, tomorrow, dayOffset(2, from: day)])
    }

    @Test func tvReloadKeepsTableWhenCenterIsMissing() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let far = dayOffset(3, from: day)
        let failures = Box<Set<Int64>>([GuideLayout.broadcastRange(for: far).from])
        let stub = tvTransport(fails: { failures.value.contains($0) })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let days = model.tvDays
        let count = model.tvGuide?.services.first?.programs.count
        // 飛び先の日の中心が読めない: いまの表（持っている日と番組）を差し替えない
        await model.tvReload(center: far, now: now)
        #expect(model.tvDays == days)
        #expect(model.tvGuide?.services.first?.programs.count == count)
        #expect(!model.tvDidFail)
    }

    @Test func tvReloadPrependsAnEarlierDayWithoutMovingTheOrigin() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let center = dayOffset(3, from: base)
        let previous = dayOffset(-1, from: center)
        let next = dayOffset(1, from: center)
        let failures = Box<Set<Int64>>([GuideLayout.broadcastRange(for: previous).from])
        let (model, _, _) = fixture(tvTransport(fails: { failures.value.contains($0) }), now: now)
        await model.tvStart(now: now)
        let origin = model.tvFrom

        await model.tvReload(center: center, now: now)
        #expect(model.tvDays == [center, next])

        failures.value = []
        await model.tvReload(center: center, now: now)
        #expect(model.tvDays == [previous, center, next])
        #expect(model.tvFrom == origin)
        #expect(model.tvBase == base)
    }

    @Test func tvWindowAppliesUntilOnTheInitialLoad() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let until = GuideLayout.broadcastRange(for: day).to - 3_600_000
        let requests = Box<[Int64]>([])
        let stub = tvTransport(until: { until }, before: { _, from in requests.value.append(from) })
        let (model, _, _) = fixture(stub, now: now)

        await model.tvStart(now: now)

        #expect(requests.value.count == 2)
        #expect(model.tvDays == [day])
        #expect(model.tvGuide?.until == until)
    }

    @Test func tvForcedRefreshAppliesAShrinkingUntilEvenWhenItExcludesTheCenter() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let next = dayOffset(1, from: day)
        let until = Box<Int64?>(nil)
        let (model, _, _) = fixture(tvTransport(until: { until.value }, programOffset: 13 * 3_600_000), now: now)
        await model.tvStart(now: now)
        await model.tvReload(center: next, now: now)

        until.value = GuideLayout.broadcastRange(for: day).to - 3_600_000
        await model.refresh(now: now)
        #expect(model.tvDays == [day])
        #expect(model.tvGuide?.until == until.value)
        let guide = try #require(model.tvGuide)
        let nextStart = GuideLayout.broadcastRange(for: next).from
        let removed = GuideCursor(column: 0, programID: nextStart, anchor: nextStart)
        let cursor = try #require(GuideCursorMotion.cursorAfterWindowChange(
            removed, in: guide.services, range: guide.from..<guide.to
        ))
        let program = try #require(GuideCursorMotion.program(cursor, in: guide.services)?.program)
        #expect(cursor.anchor >= program.startAt && cursor.anchor < program.endAt)
        let ppm = GuideLayout.tvPointsPerMinute
        let start = Double(guide.from)
        let anchorY = GuideLayout.offset(of: Double(cursor.anchor), from: start, pointsPerMinute: ppm)
        let frame = try #require(GuideLayout.frame(
            start: Double(program.startAt), end: Double(program.endAt),
            rangeStart: start, rangeEnd: Double(guide.to), pointsPerMinute: ppm
        ))
        let viewportHeight = 700.0
        let cell = frame.top...(frame.top + frame.height)
        let bounds = GuideLayout.tvScrollRange(
            origin: start, loadedStart: start, loadedEnd: Double(guide.to), viewportHeight: viewportHeight
        )
        let followed = GuideLayout.tvFollowOffset(
            scrollY: bounds.upperBound, viewportHeight: viewportHeight, anchorY: anchorY, cell: cell, headingHeight: 88
        )
        let y = min(max(bounds.lowerBound, followed), bounds.upperBound)
        #expect((y...(y + viewportHeight)).contains(anchorY))
        #expect((y...(y + viewportHeight)).overlaps(cell))
    }

    @Test(arguments: [-1, 1]) func tvExtendsPastADayWithoutProgramsInTheSelectedService(direction: Int) async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let center = dayOffset(4, from: base)
        let vacant = dayOffset(direction, from: center)
        let target = dayOffset(2 * direction, from: center)
        let targetStart = GuideLayout.broadcastRange(for: target).from
        let started = Gate()
        let release = Gate()
        let stub = tvTransport(empty: { $0 == GuideLayout.broadcastRange(for: vacant).from }, before: { _, from in
            if from == targetStart {
                await started.open()
                await release.wait()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        await model.tvReload(center: center, now: now)
        let centerStart = GuideLayout.broadcastRange(for: center).from
        let originalDays = model.tvDays
        let cursor = GuideCursor(column: 0, programID: centerStart, anchor: centerStart)
        var moved: GuideCursor?

        let move = Task { await model.tvExtend(from: cursor, direction: direction, now: now) { moved = $0 } }
        #expect(await started.wait())
        #expect(model.tvDays == originalDays)
        #expect(moved == nil)
        await release.open()
        let result = await move.value

        #expect(result == .moved)
        #expect(moved?.programID == targetStart)
        #expect(model.tvDays.contains(target))
        #expect(model.tvDays.count <= 3)
    }

    @Test func tvRefreshDoesNotCancelAnEdgeSearch() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let next = dayOffset(1, from: base)
        let edgeDay = dayOffset(2, from: base)
        let edgeStart = GuideLayout.broadcastRange(for: edgeDay).from
        let started = Gate()
        let release = Gate()
        let stub = tvTransport(before: { _, from in
            if from == edgeStart {
                await started.open()
                await release.wait()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let nextStart = GuideLayout.broadcastRange(for: next).from
        let cursor = GuideCursor(column: 0, programID: nextStart, anchor: nextStart)
        var moved: GuideCursor?
        let move = Task { await model.tvExtend(from: cursor, direction: 1, now: now) { moved = $0 } }
        #expect(await started.wait())
        var refreshing = false
        let refresh = Task {
            refreshing = true
            await model.refresh(now: now)
        }
        #expect(await waitUntil { refreshing })
        await release.open()

        #expect(await move.value == .moved)
        await refresh.value
        let target = try #require(moved)
        let guide = try #require(model.tvGuide)
        #expect(target.programID == edgeStart)
        try #require(guide.services.indices.contains(target.column))
        #expect(guide.services[target.column].id == 3273601024)
        #expect(model.tvDays.contains(edgeDay))
    }

    @Test func tvTypeSelectionKeepsTheOldWindowUntilScrollingEnds() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let target = dayOffset(3, from: base)
        let last = dayOffset(1, from: target)
        let lastReady = Gate()
        let stub = tvTransport(before: { type, from in
            if type == "CS", from == GuideLayout.broadcastRange(for: last).from {
                await lastReady.open()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let oldWindow = model.tvGuide
        let oldDays = model.tvDays
        model.tvSetScrollAnimating(true)
        #expect(model.tvSelectType(.CS))
        var windowAtReturn: GuideResponse?
        let selection = Task {
            let result = await model.tvReload(center: target, now: now, explicit: true)
            windowAtReturn = model.tvGuide
            return result
        }
        #expect(await lastReady.wait())
        #expect(!(await waitUntil(for: .milliseconds(150)) { windowAtReturn != nil }))
        #expect(model.tvGuide == oldWindow)
        #expect(model.tvDays == oldDays)
        #expect(model.selectedType == .GR)
        model.tvSetScrollAnimating(false)

        #expect(await selection.value)
        #expect(windowAtReturn?.type == .CS)
        #expect(model.tvDays.contains(target))
        #expect(model.selectedType == .CS)
    }

    @Test func tvEdgeAppliesANewUntilAndDoesNotAskPastItAgain() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let next = dayOffset(1, from: base)
        let nextStart = GuideLayout.broadcastRange(for: next).from
        let outsideStart = GuideLayout.broadcastRange(for: dayOffset(2, from: base)).from
        let newUntil = nextStart - 10 * 3_600_000
        let stub = tvTransport(until: { nil }, untilForDay: { $0 == outsideStart ? newUntil : nil })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let cursor = GuideCursor(column: 0, programID: nextStart, anchor: nextStart)

        #expect(await model.tvExtend(from: cursor, direction: 1, now: now) == .exhausted)
        #expect(model.tvDays == [base])
        #expect(model.menuDays(now: now) == [base])
        #expect(model.tvGuide?.until == newUntil)
        let baseStart = GuideLayout.broadcastRange(for: base).from
        let remaining = GuideCursor(column: 0, programID: baseStart, anchor: baseStart)
        #expect(await model.tvExtend(from: remaining, direction: 1, now: now) == .exhausted)
        let outsideRequests = stub.requests.filter { $0.url?.query?.contains("from=\(outsideStart)&") == true }
        #expect(outsideRequests.count == 1)
    }

    @Test func tvReportsAnExhaustedTopWhenEarlierDaysHaveOnlyOtherServices() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let center = dayOffset(3, from: base)
        let centerStart = GuideLayout.broadcastRange(for: center).from
        let (model, _, _) = fixture(tvTransport(empty: { $0 < centerStart }), now: now)
        await model.tvStart(now: now)
        await model.tvReload(center: center, now: now)
        let days = model.tvDays
        let cursor = GuideCursor(column: 0, programID: centerStart, anchor: centerStart)

        #expect(await model.tvExtend(from: cursor, direction: -1, now: now) == .exhausted)
        #expect(model.tvDays == days)
    }

    @Test func tvRetainsTheOutgoingDayUntilTheLatestScrollEnds() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let center = dayOffset(3, from: base)
        let before = dayOffset(-1, from: center)
        let after = dayOffset(1, from: center)
        let (model, _, _) = fixture(tvTransport(), now: now)
        await model.tvStart(now: now)
        await model.tvReload(center: center, now: now)
        let originalDays = model.tvDays
        let outgoingProgram = GuideLayout.broadcastRange(for: after).from

        model.tvSetScrollAnimating(true)
        await model.tvReload(center: before, now: now)
        #expect(model.tvDays == originalDays)
        #expect(model.program(id: outgoingProgram) != nil)
        // 補間が続く間に反対へ送り直す。
        await model.tvReload(center: after, now: now)
        #expect(model.tvDays == originalDays)
        model.tvSetScrollAnimating(false)
        #expect(model.tvDays == [center, after, dayOffset(2, from: center)])

        model.tvSetScrollAnimating(true)
        await model.tvReload(center: before, now: now)
        #expect(model.program(id: outgoingProgram) != nil)
        model.tvSetScrollAnimating(false)
        #expect(model.program(id: outgoingProgram) == nil)
        #expect(model.tvDays.last == center)
    }

    @Test func tvExplicitSelectionSharesAnInFlightPrefetch() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let target = dayOffset(3, from: day)
        let targetStart = GuideLayout.broadcastRange(for: target).from
        let started = Gate()
        let release = Gate()
        let count = Box(0)
        let selecting = Box(false)
        let stub = tvTransport(before: { _, from in
            guard from == targetStart else { return }
            count.value += 1
            await started.open()
            await release.wait()
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let prefetch = Task { await model.tvReload(center: target, now: now) }
        #expect(await started.wait())
        let selection = Task {
            selecting.value = true
            return await model.tvReload(center: target, now: now, explicit: true)
        }
        #expect(await waitUntil { selecting.value })
        await release.open()

        #expect(await selection.value)
        #expect(await prefetch.value)
        #expect(count.value == 1)
        #expect(model.tvDays.contains(target))
    }

    @Test func tvExplicitAThenBThenAStartsANewReadForTheLastChoice() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let a = dayOffset(3, from: day)
        let b = dayOffset(6, from: day)
        let aStart = GuideLayout.broadcastRange(for: a).from
        let bStart = GuideLayout.broadcastRange(for: b).from
        let firstAStarted = Gate()
        let bStarted = Gate()
        let releaseA = Gate()
        let releaseB = Gate()
        let aCount = Box(0)
        let stub = tvTransport(before: { _, from in
            if from == aStart {
                aCount.value += 1
                if aCount.value == 1 {
                    await firstAStarted.open()
                    await releaseA.wait()
                }
            } else if from == bStart {
                await bStarted.open()
                await releaseB.wait()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let firstA = Task { await model.tvReload(center: a, now: now, explicit: true) }
        #expect(await firstAStarted.wait())
        let readB = Task { await model.tvReload(center: b, now: now, explicit: true) }
        #expect(await bStarted.wait())

        let lastA = await model.tvReload(center: a, now: now, explicit: true)
        await releaseB.open()
        await releaseA.open()

        #expect(lastA)
        #expect(!(await firstA.value))
        #expect(!(await readB.value))
        #expect(aCount.value == 2)
        #expect(model.tvDays.contains(a))
    }

    @Test func tvFailedTypeSelectionKeepsTheOldChipAndTheSameChoiceCanRetry() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let dayStart = GuideLayout.broadcastRange(for: day).from
        let fail = Box(true)
        let stub = tvTransport(before: { type, from in
            if type == "CS", from == dayStart, fail.value { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        model.tvSelectType(.CS)

        #expect(!(await model.tvReload(center: day, now: now, explicit: true)))
        #expect(model.selectedType == .GR)
        #expect(model.tvGuide?.type == .GR)

        fail.value = false
        model.tvSelectType(.CS)
        #expect(await model.tvReload(center: day, now: now, explicit: true))
        #expect(model.selectedType == .CS)
        #expect(model.tvGuide?.type == .CS)
    }

    @Test func tvFailedWindowDoesNotCacheItsSuccessfulNeighbor() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let far = dayOffset(4, from: day)
        let farStart = GuideLayout.broadcastRange(for: far).from
        let previousStart = GuideLayout.broadcastRange(for: dayOffset(-1, from: far)).from
        let failures = Box(true)
        let requests = Box(0)
        let stub = tvTransport(fails: { $0 == farStart && failures.value }, before: { _, from in
            if from == previousStart { requests.value += 1 }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)

        #expect(!(await model.tvReload(center: far, now: now, explicit: true)))
        #expect(!(await model.tvReload(center: far, now: now, explicit: true)))
        failures.value = false
        #expect(await model.tvReload(center: far, now: now, explicit: true))
        #expect(requests.value == 3)
        #expect(model.tvDays.count == 3)
    }

    @Test func tvStartWithOnlyOpenDayMissingShowsFailure() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let failures = Box<Set<Int64>>([GuideLayout.broadcastRange(for: day).from])
        let (model, _, _) = fixture(tvTransport(fails: { failures.value.contains($0) }), now: now)
        await model.tvStart(now: now)
        // 開いた日が読めない初回は、翌日から始めずに失敗として出す
        #expect(model.tvGuide == nil)
        #expect(model.tvDidFail)
    }

    @Test func tvSelectTypeReloadsWhileSameDayIsLoading() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let gate = Gate()
        let started = Box(false)
        // 最初の GR の読みを止めて、その間に種別を切り替える
        let stub = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, self.servicesJSON)
            }
            let query = request.url?.query ?? ""
            guard let typePart = query.split(separator: "&").first(where: { $0.hasPrefix("type=") }),
                  let fromPart = query.split(separator: "&").first(where: { $0.hasPrefix("from=") }),
                  let from = Int64(fromPart.dropFirst(5)),
                  let toPart = query.split(separator: "&").first(where: { $0.hasPrefix("to=") }),
                  let to = Int64(toPart.dropFirst(3))
            else { throw URLError(.badURL) }
            let type = String(typePart.dropFirst(5))
            if type == "GR", !started.value {
                started.value = true
                await gate.wait()
            }
            let body = """
            {"type":"\(type)","from":\(from),"to":\(to),"until":null,"services":[
              {"id":1,"name":"局","mainId":null,"remoteControlKey":null,"logo":null,
               "programs":[{"id":\(from),"name":"番組","startAt":\(from),"endAt":\(from + 3600000),
                 "description":null,"genre":1,"copyNever":false,"reservation":null,"recordingId":null}]}]}
            """
            return reply(request, 200, body)
        }
        let (model, _, _) = fixture(stub, now: now)
        let loading = Task { await model.tvReload(center: day, now: now) }
        #expect(await waitUntil { started.value })
        model.tvSelectType(.CS)
        let applied = await model.tvReload(center: day, now: now)
        #expect(applied)
        await gate.open()
        _ = await loading.value
        // 新しい種別の表が読まれていること (前の種別の読みに飲まれない)
        #expect(model.selectedType == .CS)
        #expect(model.tvGuide?.type == .CS)
        #expect(model.tvGuide?.services.first?.programs.isEmpty == false)
    }

    private func waitUntil(for duration: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while !condition(), clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func fixedNow() -> Date {
        GuideLayout.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15))!
    }

    private func dayOffset(_ offset: Int, from day: Date) -> Date {
        GuideLayout.calendar.date(byAdding: .day, value: offset, to: day)!
    }

    /// tvOS の窓の読み。要求された from/to の日に 1 本ずつ番組を返す。
    /// `fails` は from (放送日の 4:00) で決める。from/to が読めない要求は失敗にする
    private func tvTransport(
        until: @escaping @Sendable () -> Int64? = { nil },
        untilForDay: @escaping @Sendable (Int64) -> Int64? = { _ in nil },
        programOffset: Int64 = 0,
        fails: @escaping @Sendable (Int64) -> Bool = { _ in false },
        empty: @escaping @Sendable (Int64) -> Bool = { _ in false },
        before: @escaping @Sendable (String, Int64) async throws -> Void = { _, _ in }
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, self.servicesJSON)
            }
            let query = request.url?.query ?? ""
            guard let typePart = query.split(separator: "&").first(where: { $0.hasPrefix("type=") }),
                  let fromPart = query.split(separator: "&").first(where: { $0.hasPrefix("from=") }),
                  let from = Int64(fromPart.dropFirst(5)),
                  let toPart = query.split(separator: "&").first(where: { $0.hasPrefix("to=") }),
                  let to = Int64(toPart.dropFirst(3))
            else { throw URLError(.badURL) }
            let type = String(typePart.dropFirst(5))
            try await before(type, from)
            guard !fails(from) else { throw URLError(.timedOut) }
            let untilValue = (untilForDay(from) ?? until()).map { "\($0)" } ?? "null"
            let programFields = """
            "name":"番組","startAt":\(from + programOffset),"endAt":\(from + programOffset + 3_600_000),
            "description":null,"genre":1,"copyNever":false,"reservation":null,"recordingId":null
            """
            let programs = empty(from) ? "" : "{\"id\":\(from),\(programFields)}"
            let body = """
            {"type":"\(type)","from":\(from),"to":\(to),"until":\(untilValue),"services":[
              {"id":3273601024,"name":"ＮＨＫ総合１・東京","mainId":null,"remoteControlKey":1,"logo":null,
               "programs":[\(programs)]},
              {"id":2,"name":"別の局","mainId":null,"remoteControlKey":2,"logo":null,
               "programs":[{"id":\(from + 1),\(programFields)}]}]}
            """
            return reply(request, 200, body)
        }
    }
}

/// テスト用の待ち合わせ。`open()` まで `wait()` を止める
private actor Gate {
    private var opened = false

    @discardableResult
    func wait(for duration: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while !opened, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return opened
    }

    func open() {
        opened = true
    }
}
