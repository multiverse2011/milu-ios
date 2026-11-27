import Foundation
import Testing
@testable import Milu

@Suite struct DenpaClientTests {
    private let base = URL(string: "http://denpa.lan:3000")!

    @Test func unauthorizedAndInvalidTokenAreDistinct() async {
        let unauthorized = StubTransport { request in
            reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        await #expect(throws: DenpaError.unauthorized) {
            try await DenpaClient(baseURL: base, token: nil, transport: unauthorized).send("api/services")
        }

        let invalid = StubTransport { request in
            reply(request, 401, #"{"error":"invalid_token"}"#)
        }
        await #expect(throws: DenpaError.invalidToken) {
            try await DenpaClient(baseURL: base, token: "old", transport: invalid).send("api/services")
        }
    }

    @Test func writesSetContentTypeAndBearer() async throws {
        let transport = StubTransport { request in
            reply(request, 200, #"{"deviceCode":"d"}"#)
        }
        let client = DenpaClient(baseURL: base, token: "denpa_x", transport: transport)
        _ = try await client.post("api/device/code", body: ["name": "居間のテレビ"])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer denpa_x")
        #expect(request.url == base.appending(path: "api/device/code"))
    }

    @Test func keepsTheQueryOfAListPath() async throws {
        let base = URL(string: "http://127.0.0.1:3000")!
        let client = DenpaClient(baseURL: base, token: nil)
        let url = client.url("api/recordings?limit=50&offset=50")
        #expect(url.path == "/api/recordings")
        #expect(url.query == "limit=50&offset=50")
        #expect(client.url("api/services").query == nil)
    }

    @Test func bodylessWriteStillSetsContentType() async throws {
        let transport = StubTransport { request in
            reply(request, 204)
        }
        let client = DenpaClient(baseURL: base, token: "denpa_x", transport: transport)
        _ = try await client.post("api/device/logout")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == nil)
    }

    @Test func serverMessageIsKept() async {
        let transport = StubTransport { request in
            reply(request, 503, #"{"message":"サーバが混んでいます"}"#)
        }
        do {
            _ = try await DenpaClient(baseURL: base, token: nil, transport: transport).send("api/recordings/1")
            Issue.record("失敗するはず")
        } catch let error as DenpaError {
            #expect(error == .http(status: 503, message: "サーバが混んでいます"))
        } catch {
            Issue.record("DenpaError ではない: \(error)")
        }
    }

    @Test func serviceListShape() {
        #expect(DenpaClient.isServiceList(Data("[]".utf8)))
        let service = #"[{"id":1,"type":"GR","name":"NHK","live":"api/services/1/live","airing":true,"video":true}]"#
        #expect(DenpaClient.isServiceList(Data(service.utf8)))
        // 局の形になっていない配列は denpa ではない
        #expect(!DenpaClient.isServiceList(Data(#"[{"id":1}]"#.utf8)))
        // 知らない種別の局だけでも denpa とみなす
        let unknownType = #"[{"id":1,"type":"NEW","name":"新しい局"}]"#
        #expect(DenpaClient.isServiceList(Data(unknownType.utf8)))
        // 家の LAN のダッシュボード
        let dashboard = #"[{"name":"Rec","services":[{"name":"Milu","href":"http://denpa.lan:3000"}]}]"#
        #expect(!DenpaClient.isServiceList(Data(dashboard.utf8)))
        #expect(!DenpaClient.isServiceList(Data(#"{"services":[]}"#.utf8)))
        #expect(!DenpaClient.isServiceList(Data("<html></html>".utf8)))
    }
}
