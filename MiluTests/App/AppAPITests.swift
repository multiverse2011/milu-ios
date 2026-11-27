import Foundation
import Testing
@testable import Milu

@Suite struct AppAPITests {
    private func appModel(
        _ transport: StubTransport,
        token: String?
    ) -> (AppModel, StubTokenStore, UserDefaults) {
        let url = URL(string: "http://127.0.0.1:3000")!
        let tokens = StubTokenStore(token.map { [url: $0] } ?? [:])
        let name = "AppAPITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(url.absoluteString, forKey: "serverURL")
        let model = AppModel(
            service: ConnectionService(transport: transport),
            keychain: tokens,
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (model, tokens, defaults)
    }

    @Test func invalidTokenRetriesWithoutToken() async throws {
        let transport = StubTransport { request in
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return reply(request, 401, #"{"error":"invalid_token"}"#)
            }
            return reply(request, 200, #"{"ok":true}"#)
        }
        let (model, tokens, _) = appModel(transport, token: "old")
        #expect(model.server?.token == "old")
        let data = try await model.get("api/recordings")
        #expect(data == Data(#"{"ok":true}"#.utf8))
        #expect(model.server?.token == nil)
        #expect(tokens.saved.isEmpty)
    }

    @Test func invalidTokenThenUnauthorizedStartsPairing() async {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":600}"#
                )
            }
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return reply(request, 401, #"{"error":"invalid_token"}"#)
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let (model, tokens, _) = appModel(transport, token: "old")
        do {
            _ = try await model.get("api/services")
            Issue.record("needsPairing になるはず")
        } catch let error as AppModel.APIError {
            #expect(error == .needsPairing)
        } catch {
            Issue.record("APIError ではない: \(error)")
        }
        #expect(model.server?.token == nil)
        #expect(model.pairing != nil)
        #expect(tokens.saved.isEmpty)
        model.cancelPairing()
    }
}
