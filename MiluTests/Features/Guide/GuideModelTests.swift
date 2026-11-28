import Foundation
import Testing

@testable import Milu

/// GuideModel (番組表のタブの状態) の単体テスト。
@Suite(.timeLimit(.minutes(1))) struct GuideModelTests {
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

    // MARK: tvOS の全日取得

    private func response(
        from: Int64,
        to: Int64,
        programs: [(id: Int64, startAt: Int64)]
    ) -> GuideResponse {
        GuideResponse(
            type: .GR,
            from: from,
            to: to,
            until: nil,
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
        let first = response(from: 1_000, to: 9_000, programs: [(1, 2_000), (2, 5_000)])
        let second = response(from: 9_000, to: 17_000, programs: [(2, 5_000), (3, 9_000)])
        let merged = GuideModel.merge([second, first])
        // 2 日目にも出てくる番組は 1 つにまとめ、始まり順に並べる
        #expect(merged.first?.programs.map(\.id) == [1, 2, 3])
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
        let merged = GuideModel.merge([
            guide(from: boundary - 86_400_000, to: boundary, programs: [reserved]),
            guide(from: boundary, to: boundary + 86_400_000, programs: [crossing]),
        ])
        let programs = try #require(merged.first?.programs)
        #expect(programs.map(\.id) == [7])
        #expect(programs.first?.reservation != nil)
    }

    @Test func iosReloadLeavesTVStateEmpty() async throws {
        let stub = transport(services: servicesJSON, programs: guideJSON(nil))
        let (model, _, _) = fixture(stub)
        await model.reload()
        #expect(model.guide != nil)
        // iOS の読みは tvOS の全日取得に触らない
        #expect(model.tvGuide == nil)
        #expect(model.tvDays.isEmpty)
    }

    @Test func tvPublishesTodayFirstAndAddsDaysInResponseOrder() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let days = (0...5).map { dayOffset($0, from: base) }
        let starts = days.map(dayStart)
        let todayStarted = Gate()
        let slowStarted = Gate()
        let releaseToday = Gate()
        let releaseSlow = Gate()
        let releaseFast = Gate()
        let stub = tvTransport(until: { starts[5] + 3_600_000 }, before: { _, from in
            if from == starts[0] {
                await todayStarted.open()
                try await releaseToday.requireOpen()
            } else if from == starts[1] || from == starts[3] {
                await slowStarted.open()
                try await releaseSlow.requireOpen()
            } else if from == starts[2] {
                try await releaseFast.requireOpen()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        let start = startOperation { await model.tvStart(now: now) }
        #expect(await todayStarted.wait())
        #expect(programRequestDays(stub) == [starts[0]])
        #expect(model.tvGuide == nil)
        await releaseToday.open()
        #expect(await slowStarted.wait())
        #expect(await waitUntil { programRequestDays(stub).count >= 4 })
        #expect(!(await waitUntil(for: .milliseconds(30)) { programRequestDays(stub).count > 4 }))
        #expect(Set(programRequestDays(stub)) == Set(starts.prefix(4)))
        #expect(model.program(id: starts[0]) != nil)
        await releaseFast.open()

        #expect(await waitUntil { model.program(id: starts[2]) != nil })
        #expect(model.program(id: starts[0]) != nil)
        #expect(model.program(id: starts[1]) == nil)
        let origin = model.tvFrom
        #expect(origin == starts[0])
        let before = GuideLayout.offset(of: Double(starts[2]), from: Double(origin), pointsPerMinute: GuideLayout.tvPointsPerMinute)
        await releaseSlow.open()
        #expect(await start.wait())

        #expect(model.tvDays == days)
        #expect(model.program(id: starts[1]) != nil)
        #expect(model.program(id: starts[5]) != nil)
        #expect(model.tvFrom == origin)
        let after = GuideLayout.offset(of: Double(starts[2]), from: Double(model.tvFrom), pointsPerMinute: GuideLayout.tvPointsPerMinute)
        #expect(after == before)
    }

    @Test func tvMissingDayStaysEmptyAndOnlyOneDownRetryRunsBeforeRefresh() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let missing = dayOffset(1, from: base)
        let later = dayOffset(2, from: base)
        let missingStart = dayStart(missing)
        let laterStart = dayStart(later)
        let fails = Box(true)
        let retryStarted = Gate()
        let releaseRetry = Gate()
        let isRetry = Box(false)
        let stub = tvTransport(until: { laterStart + 3_600_000 }, before: { _, from in
            if from == missingStart, isRetry.value {
                await retryStarted.open()
                try await releaseRetry.requireOpen()
            }
            if from == missingStart, fails.value { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        #expect(model.tvDays == [base, missing, later])
        #expect(model.program(id: missingStart) == nil)
        #expect(model.program(id: laterStart) != nil)
        #expect(model.tvBlockingDay(after: dayStart(base), before: laterStart) == missing)

        isRetry.value = true
        let retry = startOperation { await model.tvRetry(day: missing) }
        #expect(await retryStarted.wait())
        await model.tvRetry(day: missing)
        #expect(model.tvBlockingDay(after: dayStart(base), before: laterStart) == missing)
        await releaseRetry.open()
        #expect(await retry.wait())
        await model.tvRetry(day: missing)
        #expect(programRequestDays(stub).filter { $0 == missingStart }.count == 2)
        #expect(model.program(id: missingStart) == nil)
        #expect(model.tvBlockingDay(after: dayStart(base), before: laterStart) == nil)

        fails.value = false
        await model.refresh(now: now)
        #expect(model.program(id: missingStart) != nil)
        #expect(programRequestDays(stub).filter { $0 == missingStart }.count == 3)
    }

    @Test func tvDownAtTheLastProgramRetriesTheFirstOfTheMissingFinalDays() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let today = dayStart(base)
        let tomorrow = dayOffset(1, from: base)
        let tomorrowStart = dayStart(tomorrow)
        let last = dayStart(dayOffset(2, from: base))
        let stub = tvTransport(until: { last + 3_600_000 }, before: { _, from in
            if from > today { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)

        let guide = try #require(model.tvGuide)
        let cursor = try #require(GuideCursorMotion.cursor(at: 0, anchor: today, in: guide.services))
        let next = GuideCursorMotion.vertical(cursor, in: guide.services, by: 1)
        #expect(next == nil)
        let retryDay = try #require(model.tvBlockingDay(after: cursor.anchor, before: next?.anchor))
        #expect(retryDay == tomorrow)
        await model.tvRetry(day: retryDay)
        await model.tvRetry(day: retryDay)
        #expect(programRequestDays(stub).filter { $0 == tomorrowStart }.count == 2)
        #expect(programRequestDays(stub).filter { $0 == last }.count == 1)
    }

    @Test(arguments: ["POST", "DELETE"])
    func tvRecordingChangeWaitsForTodayWhileLaterDaysRefreshIndependently(method: String) async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let today = dayStart(base)
        let tomorrow = dayStart(dayOffset(1, from: base))
        let changed = Box(false)
        let todayStarted = Gate()
        let releaseToday = Gate()
        let tomorrowStarted = Gate()
        let releaseTomorrow = Gate()
        let stub = tvTransport(
            until: { tomorrow + 3_600_000 }, title: { changed.value ? "更新後" : "更新前" },
            record: { request in
                #expect(request.httpMethod == method)
                changed.value = true
                return reply(request, 200, #"{"recorded":"番組","reserved":true,"state":"scheduled"}"#)
            },
            before: { _, from in
                guard changed.value else { return }
                if from == today {
                    await todayStarted.open()
                    try await releaseToday.requireOpen()
                } else if from == tomorrow {
                    await tomorrowStarted.open()
                    try await releaseTomorrow.requireOpen()
                }
            }
        )
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let item = try #require(model.program(id: today))
        let done = startOperation {
            let error = if method == "POST" { await model.reserve(item) } else { await model.cancel(item) }
            #expect(error == nil)
        }

        #expect(await todayStarted.wait())
        #expect(!(await done.wait(for: .milliseconds(30))))
        await releaseToday.open()
        #expect(await tomorrowStarted.wait())
        #expect(await done.wait(for: .seconds(1)))
        #expect(model.program(id: today)?.name == "更新後")
        #expect(model.program(id: tomorrow)?.name == "更新前")

        await releaseTomorrow.open()
        #expect(await done.wait())
        #expect(await waitUntil { model.program(id: tomorrow)?.name == "更新後" })
    }

    @Test(arguments: [false, true])
    func tvReservationWaitsForTheProgramDayEvenWhenItsRequestFails(fails: Bool) async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let tomorrow = dayStart(dayOffset(1, from: base))
        let last = dayStart(dayOffset(2, from: base))
        let reserved = Box(false)
        let tomorrowStarted = Gate()
        let releaseTomorrow = Gate()
        let lastStarted = Gate()
        let releaseLast = Gate()
        let stub = tvTransport(
            until: { last + 3_600_000 }, title: { reserved.value ? "更新後" : "更新前" },
            reserved: { $0 == tomorrow && reserved.value },
            record: { request in
                #expect(request.httpMethod == "POST")
                reserved.value = true
                return reply(request, 200, #"{"recorded":"番組","reserved":true,"state":"scheduled"}"#)
            },
            before: { _, from in
                guard reserved.value else { return }
                if from == tomorrow {
                    await tomorrowStarted.open()
                    try await releaseTomorrow.requireOpen()
                    if fails { throw URLError(.timedOut) }
                } else if from == last {
                    await lastStarted.open()
                    try await releaseLast.requireOpen()
                }
            }
        )
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let item = try #require(model.program(id: tomorrow))
        let done = startOperation {
            #expect(await model.reserve(item) == nil)
            #expect(model.program(id: tomorrow)?.reservation?.state == (fails ? nil : .scheduled))
        }

        #expect(await tomorrowStarted.wait())
        #expect(await lastStarted.wait())
        #expect(!(await done.wait(for: .milliseconds(100))))
        await releaseTomorrow.open()
        #expect(await done.wait(for: .seconds(1)))
        #expect(model.program(id: last)?.name == "更新前")
        await releaseLast.open()
        #expect(await waitUntil { model.program(id: last)?.name == "更新後" })
    }

    @Test func tvReservationWaitsForTheSuccessorRefreshAfterTheOriginalIsCancelled() async throws {
        let now = fixedNow()
        let today = dayStart(GuideLayout.broadcastDay(for: now))
        let refreshing = Box(false)
        let reads = Box(0)
        let oldStarted = Gate()
        let oldCancelled = Gate()
        let newStarted = Gate()
        let releaseNew = Gate()
        let stub = tvTransport(
            until: { today + 3_600_000 }, reserved: { _ in refreshing.value },
            record: { request in
                refreshing.value = true
                return reply(request, 200, #"{"recorded":"番組","reserved":true,"state":"scheduled"}"#)
            },
            before: { _, from in
                guard refreshing.value, from == today else { return }
                reads.value += 1
                if reads.value == 1 {
                    await oldStarted.open()
                    do {
                        try await Task.sleep(for: .seconds(3))
                        Issue.record("旧世代の取得が取り消されなかった")
                    } catch {
                        await oldCancelled.open()
                        throw error
                    }
                } else {
                    await newStarted.open()
                    try await releaseNew.requireOpen()
                }
            }
        )
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let item = try #require(model.program(id: today))
        let done = startOperation {
            #expect(await model.reserve(item) == nil)
            #expect(model.program(id: today)?.reservation?.state == .scheduled)
        }
        #expect(await oldStarted.wait())
        let refreshed = startOperation { await model.refresh(now: now) }
        #expect(await newStarted.wait())
        #expect(await oldCancelled.wait())
        #expect(!(await done.wait(for: .milliseconds(100))))
        await releaseNew.open()
        #expect(await done.wait(for: .seconds(1)))
        #expect(await refreshed.wait())
    }

    @Test func tvCancellationClearsACrossingProgramMarkEvenWhenTheNextDayFails() async throws {
        let now = fixedNow()
        let tomorrow = dayStart(dayOffset(1, from: GuideLayout.broadcastDay(for: now)))
        let cancelled = Box(false)
        let tomorrowStarted = Gate()
        let releaseTomorrow = Gate()
        let stub = tvTransport(
            until: { tomorrow + 3_600_000 }, crossingBoundary: tomorrow,
            reserved: { _ in !cancelled.value },
            record: { request in
                #expect(request.httpMethod == "DELETE")
                cancelled.value = true
                return reply(request, 200, "{}")
            },
            before: { _, from in
                if cancelled.value, from == tomorrow {
                    await tomorrowStarted.open()
                    try await releaseTomorrow.requireOpen()
                    throw URLError(.timedOut)
                }
            }
        )
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let item = try #require(model.program(id: tomorrow - 600_000))
        #expect(item.reservation?.state == .scheduled)
        let done = startOperation { #expect(await model.cancel(item) == nil) }
        #expect(await tomorrowStarted.wait())
        #expect(!(await done.wait(for: .milliseconds(100))))
        await releaseTomorrow.open()
        #expect(await done.wait(for: .seconds(1)))
        let current = try #require(model.program(id: item.id))
        #expect(current.reservation == nil)
        #expect(current.endAt == item.endAt)
        #expect(model.program(id: tomorrow) != nil)
    }

    @Test func tvRefreshRetainsAnAlreadyLoadedDayAndItsCursorWhenItFails() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let tomorrow = dayStart(dayOffset(1, from: base))
        let last = dayStart(dayOffset(2, from: base))
        let updating = Box(false)
        let stub = tvTransport(until: { last + 3_600_000 }, title: { updating.value ? "更新後" : "更新前" }, before: { _, from in
            if updating.value, from == tomorrow { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        let before = try #require(model.tvGuide)
        let program = try #require(model.program(id: tomorrow))
        let cursor = try #require(GuideCursorMotion.cursor(at: 0, anchor: tomorrow, in: before.services))
        #expect(cursor.programID == tomorrow)

        updating.value = true
        await model.refresh(now: now)

        let after = try #require(model.tvGuide)
        #expect(model.program(id: last)?.name == "更新後")
        #expect(model.program(id: tomorrow) == program)
        #expect(GuideCursorMotion.cursorAfterRefresh(
            cursor, previous: before.services, current: after.services, range: model.tvFrom..<model.tvTo,
            hasResponse: model.tvHasResponse(at: cursor.anchor)
        ) == cursor)
        #expect(model.tvBlockingDay(after: dayStart(base), before: last) == nil)
        await model.tvRetry(day: dayOffset(1, from: base))
        #expect(programRequestDays(stub).filter { $0 == tomorrow }.count == 2)
    }

    @Test func tvRefreshCancelsTheOldRetryAndKeepsItsSlotUntilTheRequestEnds() async throws {
        let now = fixedNow()
        let missing = dayOffset(1, from: GuideLayout.broadcastDay(for: now))
        let start = dayStart(missing)
        let attempts = Box(0)
        let oldReply = Box(true)
        let oldCancelled = Box(false)
        let oldStarted = Gate()
        let releaseOld = Gate()
        let oldFinished = Gate()
        let stub = tvTransport(until: { start + 3_600_000 }, title: { oldReply.value ? "旧番組" : "新番組" }, before: { _, from in
            guard from == start else { return }
            attempts.value += 1
            switch attempts.value {
            case 1, 3:
                throw URLError(.timedOut)
            case 2:
                await oldStarted.open()
                let released = await Task.detached { await releaseOld.wait() }.value
                guard released else {
                    Issue.record("旧再試行の応答を解放できなかった")
                    throw URLError(.timedOut)
                }
                oldCancelled.value = Task.isCancelled
            default:
                break
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        Task {
            await model.tvRetry(day: missing)
            await oldFinished.open()
        }
        #expect(await oldStarted.wait())
        oldReply.value = false
        await model.refresh(now: now)
        await model.tvRetry(day: missing)
        #expect(attempts.value == 3)
        #expect(model.program(id: start) == nil)

        await releaseOld.open()
        #expect(await oldFinished.wait())
        #expect(oldCancelled.value)
        #expect(await waitUntil { model.program(id: start)?.name == "新番組" })
        #expect(attempts.value == 4)
        #expect(model.program(id: start)?.name == "新番組")
    }

    @Test func tvCrossingProgramKeepsItsBroadcastTimeWhenOnlyTheSecondDayIsRead() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let missing = dayStart(dayOffset(1, from: base))
        let boundary = dayStart(dayOffset(2, from: base))
        let id = boundary - 600_000
        let stub = tvTransport(until: { boundary + 3_600_000 }, crossingBoundary: boundary, before: { _, from in
            if from == missing { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)

        let service = try #require(model.tvGuide?.services.first)
        let segment = try #require(service.programs.first { $0.id == id })
        #expect(segment.startAt == boundary)
        #expect(segment.endAt == boundary + 1_200_000)
        let item = GuideProgramItem(service: service, program: segment)
        #expect(item.startAt == id)
        #expect(item.endAt == boundary + 1_200_000)
        #expect(model.program(id: id) == item)
    }

    @Test func tvCrossingProgramStopsAtTheMissingDayAndRejoinsAfterRetry() async throws {
        let now = fixedNow()
        let missing = dayOffset(1, from: GuideLayout.broadcastDay(for: now))
        let boundary = dayStart(missing)
        let fail = Box(true)
        let id = boundary - 600_000
        let stub = tvTransport(until: { boundary + 3_600_000 }, crossingBoundary: boundary, before: { _, from in
            if from == boundary, fail.value { throw URLError(.timedOut) }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)

        let before = try #require(model.tvGuide?.services)
        let shortened = try #require(before.first?.programs.first { $0.id == id })
        #expect(shortened.startAt == id)
        #expect(shortened.endAt == boundary)
        #expect(model.program(id: id)?.endAt == boundary + 1_200_000)
        let empty = try #require(GuideCursorMotion.cursor(at: 0, anchor: boundary, in: before))
        #expect(GuideCursorMotion.selectedCursor(inColumn: 0, from: empty, in: before) == nil)

        fail.value = false
        await model.tvRetry(day: missing)
        let after = try #require(model.tvGuide?.services)
        let joined = try #require(after.first?.programs.filter { $0.id == id })
        #expect(joined.count == 1)
        #expect(joined.first?.startAt == id)
        #expect(joined.first?.endAt == boundary + 1_200_000)
        #expect(GuideCursorMotion.cursorAfterRefresh(
            empty, previous: before, current: after, range: model.tvFrom..<model.tvTo
        )?.programID == id)
    }

    @Test func tvRefreshDiscardsLateResponsesShrinksDaysAndRestoresCursor() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let tomorrow = dayOffset(1, from: base)
        let removed = dayOffset(2, from: base)
        let tomorrowStart = dayStart(tomorrow)
        let removedStart = dayStart(removed)
        let cutoff = Box(removedStart + 18 * 3_600_000)
        let old = Box(true)
        let staleStarted = Gate()
        let releaseStale = Gate()
        let stub = tvTransport(
            until: { cutoff.value },
            title: { old.value ? "旧番組" : "新番組" },
            programOffset: 13 * 3_600_000,
            before: { _, from in
                if from == tomorrowStart, old.value {
                    await staleStarted.open()
                    try await Task.detached { try await releaseStale.requireOpen() }.value
                }
            }
        )
        let (model, _, _) = fixture(stub, now: now)
        let start = startOperation { await model.tvStart(now: now) }
        #expect(await staleStarted.wait())
        #expect(await waitUntil { model.program(id: removedStart) != nil })
        let previous = model.tvGuide
        old.value = false
        let newUntil = tomorrowStart + 14 * 3_600_000
        cutoff.value = newUntil
        await model.refresh(now: now)
        await releaseStale.open()
        #expect(await start.wait())

        #expect(model.tvDays == [base, tomorrow])
        #expect(model.tvGuide?.until == newUntil)
        #expect(model.program(id: tomorrowStart)?.name == "新番組")
        #expect(model.program(id: removedStart) == nil)
        let guide = try #require(model.tvGuide)
        let displaced = GuideCursor(column: 0, programID: removedStart, anchor: removedStart)
        let previousGuide = try #require(previous)
        let cursor = try #require(GuideCursorMotion.cursorAfterRefresh(
            displaced, previous: previousGuide.services, current: guide.services, range: model.tvFrom..<model.tvTo
        ))
        let program = try #require(GuideCursorMotion.program(cursor, in: guide.services)?.program)
        #expect(program.id == tomorrowStart)
        #expect(program.startAt <= cursor.anchor && cursor.anchor < program.endAt)
        let startY = Double(model.tvFrom)
        let ppm = GuideLayout.tvPointsPerMinute
        let top = GuideLayout.offset(of: Double(program.startAt), from: startY, pointsPerMinute: ppm)
        let bottom = GuideLayout.offset(of: Double(program.endAt), from: startY, pointsPerMinute: ppm)
        let cell = top...bottom
        let anchorY = GuideLayout.offset(of: Double(cursor.anchor), from: startY, pointsPerMinute: ppm)
        let height = 700.0
        let maxY = GuideLayout.tvScrollRange(
            origin: startY, end: Double(model.tvTo), viewportHeight: height
        ).upperBound
        let y = GuideLayout.tvFollowOffset(
            scrollY: maxY, viewportHeight: height, anchorY: anchorY, cell: cell, headingHeight: 88
        )
        #expect((y...(y + height)).contains(anchorY))
        #expect((y...(y + height)).overlaps(cell))
    }

    @Test func tvTypeSelectionKeepsTheOldTableOnFailureAndPublishesNewTodayFirst() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let todayStart = dayStart(day)
        let nextStart = dayStart(dayOffset(1, from: day))
        let fail = Box(true)
        let nextStarted = Gate()
        let releaseNext = Gate()
        let stub = tvTransport(until: { nextStart + 3_600_000 }, before: { type, from in
            guard type == "CS" else { return }
            if from == todayStart, fail.value { throw URLError(.timedOut) }
            if from == nextStart {
                await nextStarted.open()
                try await releaseNext.requireOpen()
            }
        })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        await model.tvSelectType(.CS, now: now)
        #expect(model.selectedType == .GR)
        #expect(model.tvGuide?.type == .GR)
        #expect(model.program(id: nextStart) != nil)
        #expect(stub.requests.filter { $0.url?.query?.contains("type=CS&") == true }.count == 1)

        fail.value = false
        let selection = startOperation { await model.tvSelectType(.CS, now: now) }
        #expect(await nextStarted.wait())
        #expect(model.selectedType == .CS)
        #expect(model.tvGuide?.type == .CS)
        #expect(model.program(id: todayStart) != nil)
        #expect(model.program(id: nextStart) == nil)
        await releaseNext.open()
        #expect(await selection.wait())
        #expect(model.program(id: nextStart) != nil)
    }

    @Test func tvVerticalMotionSkipsADayWithNoProgramsInTheSameService() async throws {
        let now = fixedNow()
        let base = GuideLayout.broadcastDay(for: now)
        let idleStart = dayStart(dayOffset(1, from: base))
        let lastStart = dayStart(dayOffset(2, from: base))
        let stub = tvTransport(until: { lastStart + 3_600_000 }, empty: { $0 == idleStart })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)

        let services = try #require(model.tvGuide?.services)
        let startID = dayStart(base)
        let first = GuideCursor(column: 0, programID: startID, anchor: startID)
        let next = try #require(GuideCursorMotion.vertical(first, in: services, by: 1))
        #expect(next.programID == lastStart)
        #expect(model.tvBlockingDay(after: first.anchor, before: next.anchor) == nil)
        #expect(GuideCursorMotion.vertical(next, in: services, by: -1) == first)
        #expect(services[1].programs.contains { $0.startAt == idleStart })
    }

    @Test func tvInitialTodayFailureShowsFailureAndDoesNotReadLaterDays() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        let todayStart = dayStart(day)
        let stub = tvTransport(until: { todayStart + 48 * 3_600_000 }, before: { _, _ in throw URLError(.timedOut) })
        let (model, _, _) = fixture(stub, now: now)
        await model.tvStart(now: now)
        #expect(model.tvGuide == nil)
        #expect(model.tvDidFail)
        #expect(programRequestDays(stub) == [todayStart])
    }

    private func dayStart(_ day: Date) -> Int64 {
        GuideLayout.broadcastRange(for: day).from
    }

    private func programRequestDays(_ stub: StubTransport) -> [Int64] {
        stub.requests.compactMap { request in
            let param = request.url?.query?.split(separator: "&").first { $0.hasPrefix("from=") }
            return param.flatMap { Int64($0.dropFirst(5)) }
        }
    }

    private func startOperation(_ operation: @escaping @MainActor () async -> Void) -> Gate {
        let done = Gate()
        Task {
            await operation()
            await done.open()
        }
        return done
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

    /// 要求された放送日ごとに番組を返す。from/to が読めない要求は失敗にする。
    private func tvTransport(
        until: @escaping @Sendable () -> Int64? = { nil },
        title: @escaping @Sendable () -> String = { "番組" },
        programOffset: Int64 = 0,
        crossingBoundary: Int64? = nil,
        empty: @escaping @Sendable (Int64) -> Bool = { _ in false },
        reserved: @escaping @Sendable (Int64) -> Bool = { _ in false },
        record: (@Sendable (URLRequest) -> (Data, HTTPURLResponse))? = nil,
        before: @escaping @Sendable (String, Int64) async throws -> Void = { _, _ in }
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, self.servicesJSON)
            }
            if path.hasSuffix("/record"), let record { return record(request) }
            let query = request.url?.query ?? ""
            guard let typePart = query.split(separator: "&").first(where: { $0.hasPrefix("type=") }),
                  let fromPart = query.split(separator: "&").first(where: { $0.hasPrefix("from=") }),
                  let from = Int64(fromPart.dropFirst(5)),
                  let toPart = query.split(separator: "&").first(where: { $0.hasPrefix("to=") }),
                  let to = Int64(toPart.dropFirst(3))
            else { throw URLError(.badURL) }
            let type = String(typePart.dropFirst(5))
            let untilValue = until().map { "\($0)" } ?? "null"
            let name = title()
            let reservation = reserved(from) ? #"{"state":"scheduled"}"# : "null"
            try await before(type, from)
            let programFields = """
            "name":"\(name)","startAt":\(from + programOffset),"endAt":\(from + programOffset + 3_600_000),
            "description":null,"genre":1,"copyNever":false,"reservation":\(reservation),"recordingId":null
            """
            var programs = empty(from) ? [] : ["{\"id\":\(from),\(programFields)}"]
            if let boundary = crossingBoundary, from <= boundary, boundary <= to {
                programs.append("""
                {"id":\(boundary - 600_000),"name":"日をまたぐ番組","startAt":\(boundary - 600_000),
                 "endAt":\(boundary + 1_200_000),"copyNever":false,"reservation":\(reservation)}
                """)
            }
            let body = """
            {"type":"\(type)","from":\(from),"to":\(to),"until":\(untilValue),"services":[
              {"id":3273601024,"name":"ＮＨＫ総合１・東京","mainId":null,"remoteControlKey":1,"logo":null,
               "programs":[\(programs.joined(separator: ","))]},
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

    func requireOpen() async throws {
        guard await wait() else {
            Issue.record("テスト用の応答が期限内に解放されなかった")
            throw URLError(.timedOut)
        }
    }

    func open() {
        opened = true
    }
}
