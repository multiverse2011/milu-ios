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
}
