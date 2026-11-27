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

    @Test func tvWindowStopsAtUntilDay() async throws {
        let now = fixedNow()
        let day = GuideLayout.broadcastDay(for: now)
        // サーバーの番組が翌 3:00 で終わる (翌日のチップは出ない)
        let until = GuideLayout.broadcastRange(for: day).to - 3_600_000
        let (model, _, _) = fixture(tvTransport(until: until), now: now)
        await model.tvStart(now: now)
        // 初回は until を知らないので翌日まで読む
        #expect(model.tvDays == [day, dayOffset(1, from: day)])
        await model.tvReload(center: day, now: now)
        // until が翌日の 4:00 より前なので、翌日は落ちる
        #expect(model.tvDays == [day])
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
        until: Int64? = nil,
        fails: @escaping @Sendable (Int64) -> Bool = { _ in false }
    ) -> StubTransport {
        StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, self.servicesJSON)
            }
            let query = request.url?.query ?? ""
            guard let fromPart = query.split(separator: "&").first(where: { $0.hasPrefix("from=") }),
                  let from = Int64(fromPart.dropFirst(5)),
                  let toPart = query.split(separator: "&").first(where: { $0.hasPrefix("to=") }),
                  let to = Int64(toPart.dropFirst(3))
            else { throw URLError(.badURL) }
            guard !fails(from) else { throw URLError(.timedOut) }
            let untilValue = until.map { "\($0)" } ?? "null"
            let body = """
            {"type":"GR","from":\(from),"to":\(to),"until":\(untilValue),"services":[
              {"id":3273601024,"name":"ＮＨＫ総合１・東京","mainId":null,"remoteControlKey":1,"logo":null,
               "programs":[{"id":\(from),"name":"番組","startAt":\(from),"endAt":\(from + 3600000),
                 "description":null,"genre":1,"copyNever":false,"reservation":null,"recordingId":null}]}]}
            """
            return reply(request, 200, body)
        }
    }
}
