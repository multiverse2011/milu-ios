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

    @Test func tvReloadLoadsDaysAroundCursor() async throws {
        let now = GuideLayout.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15))!
        let stub = tvTransport()
        let (model, _, _) = fixture(stub, now: now)
        await model.tvReload(center: model.selectedDay)
        #expect(model.tvDays.count == 2)
        #expect(model.tvGuide?.services.first?.programs.count == 2)
        #expect(model.tvGuide?.from == model.tvFrom)
        #expect(model.tvGuide?.to == model.tvTo)
        // 明日へ進むと、その次の日も先に読む
        let tomorrow = try #require(GuideLayout.calendar.date(byAdding: .day, value: 1, to: model.selectedDay))
        await model.tvReload(center: tomorrow)
        #expect(model.tvDays.count == 3)
        #expect(model.tvGuide?.services.first?.programs.count == 3)
    }

    @Test func tvReloadKeepsLoadedDaysOnFailure() async throws {
        let now = GuideLayout.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15))!
        let calls = Box(0)
        let stub = tvTransport { _ in
            let count = calls.value
            calls.value = count + 1
            // 最初の 2 日 (今日・明日) は返し、その先は繋がらない
            return count < 2
        }
        let (model, _, _) = fixture(stub, now: now)
        await model.tvReload(center: model.selectedDay)
        #expect(model.tvDays.count == 2)
        let tomorrow = try #require(GuideLayout.calendar.date(byAdding: .day, value: 1, to: model.selectedDay))
        await model.tvReload(center: tomorrow)
        // 読めなかった次の日は入らないが、いまある範囲はそのまま使える
        #expect(model.tvDays.count == 2)
        #expect(model.tvGuide?.services.first?.programs.count == 2)
        #expect(!model.tvDidFail)
    }

    /// tvOS の窓の読み。要求された from/to の日に 1 本ずつ番組を返す
    private func tvTransport(
        succeeds: @escaping @Sendable (Int) -> Bool = { _ in true }
    ) -> StubTransport {
        let count = Box(0)
        return StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("api/services") {
                return reply(request, 200, self.servicesJSON)
            }
            let index = count.value
            count.value = index + 1
            guard succeeds(index) else { throw URLError(.timedOut) }
            let query = request.url?.query ?? ""
            let from = Int64(query.split(separator: "&").first { $0.hasPrefix("from=") }?.dropFirst(5) ?? "") ?? 0
            let to = Int64(query.split(separator: "&").first { $0.hasPrefix("to=") }?.dropFirst(3) ?? "") ?? 0
            let body = """
            {"type":"GR","from":\(from),"to":\(to),"until":null,"services":[
              {"id":3273601024,"name":"ＮＨＫ総合１・東京","mainId":null,"remoteControlKey":1,"logo":null,
               "programs":[{"id":\(from),"name":"番組","startAt":\(from),"endAt":\(from + 3600000),
                 "description":null,"genre":1,"copyNever":false,"reservation":null,"recordingId":null}]}]}
            """
            return reply(request, 200, body)
        }
    }
}
