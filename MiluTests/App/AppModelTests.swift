import Foundation
import Testing
@testable import Milu

@Suite struct AppModelTests {
    private func makeModel(_ transport: StubTransport) -> (AppModel, UserDefaults) {
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let name = "AppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = AppModel(
            service: service,
            keychain: Keychain(service: "AppModelTests-\(UUID().uuidString)"),
            defaults: defaults,
            startsEvents: false
        )
        return (model, defaults)
    }

    /// 再起動の復元: 前のプロセスが残した接続先とトークンで、確かめの通信をせずに繋がった状態から始まる (3.5)
    @Test func launchRestoresServerAndToken() {
        let url = URL(string: "http://127.0.0.1:3000")!
        let name = "AppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(url.absoluteString, forKey: "serverURL")
        let keychain = Keychain(service: "AppModelTests-\(UUID().uuidString)")
        defer { keychain.delete(for: url) }
        keychain.save("token", for: url)
        let transport = StubTransport { request in
            reply(request, 200, "[]")
        }

        let model = AppModel(
            service: ConnectionService(transport: transport),
            keychain: keychain,
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )

        #expect(model.phase == .connected)
        #expect(model.server?.url == url)
        #expect(model.server?.token == "token")
        #expect(transport.requests.isEmpty)
    }

    @Test func reconnectReplacesServer() async {
        let transport = StubTransport { request in
            reply(request, 200, "[]")
        }
        let (model, defaults) = makeModel(transport)
        let message = await model.reconnect("http://127.0.0.1:3000")
        #expect(message == nil)
        #expect(model.server?.url == URL(string: "http://127.0.0.1:3000"))
        #expect(model.address == "127.0.0.1:3000")
        #expect(defaults.string(forKey: "serverURL") == "http://127.0.0.1:3000")
    }

    @Test func reconnectFailureKeepsOldServer() async {
        let transport = StubTransport { request in
            if request.url?.port == 3000 {
                return reply(request, 200, "[]")
            }
            return reply(request, 404, "")
        }
        let (model, _) = makeModel(transport)
        _ = await model.reconnect("http://127.0.0.1:3000")
        let old = model.server
        let message = await model.reconnect("http://127.0.0.1:3999")
        #expect(message == "denpa が見つかりません")
        #expect(model.server == old)
    }

    @Test func reconnectLoginNotConfiguredReturnsMessage() async {
        let transport = StubTransport { request in
            reply(request, 403, "")
        }
        let (model, _) = makeModel(transport)
        let message = await model.reconnect("http://127.0.0.1:3000")
        #expect(message == "この denpa にはログイン方法が設定されていないため接続できません")
    }

    @Test func late401AfterSignOutDoesNotRestoreServer() async {
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let started = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/recordings") == true {
                started.value = true
                await withCheckedContinuation { gate.value = $0 }
                return reply(request, 401, #"{"error":"invalid_token"}"#)
            }
            return reply(request, 204, "")
        }
        let (app, _) = makeModel(transport)
        let task = Task { try await app.get("api/recordings") }
        for _ in 0..<100 where !started.value {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await app.signOut()
        gate.value?.resume()
        gate.value = nil
        do {
            _ = try await task.value
            Issue.record("notConnected になるはず")
        } catch let error as AppModel.APIError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("APIError ではない: \(error)")
        }
        #expect(app.server == nil)
        #expect(app.pairing == nil)
    }

    private func makeModelWithTransport(
        _ transport: StubTransport,
        tokens: StubTokenStore = StubTokenStore()
    ) -> (AppModel, StubTokenStore, UserDefaults, String) {
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let name = "AppModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = AppModel(
            service: service,
            keychain: tokens,
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )
        return (model, tokens, defaults, name)
    }

    @Test func connectNeedsPairingCancelAndRetry() async {
        let codeCalls = Box(0)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                codeCalls.value += 1
                return reply(
                    request, 200,
                    #"{"deviceCode":"d-\#(codeCalls.value)","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":600}"#
                )
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let (model, _, defaults, suiteName) = makeModelWithTransport(transport)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.address = "http://127.0.0.1:3000"

        await model.connectField()
        let first = model.pairing
        #expect(first != nil)
        #expect(model.server == nil)
        #expect(model.phase == .idle)

        // スワイプや戻るで二重に呼ばれても壊れないこと
        model.cancelPairing(first)
        model.cancelPairing(first)
        model.cancelPairing()
        #expect(model.pairing == nil)
        #expect(model.server == nil)

        // 戻ったあとペアリングの状態が残っておらず、もう一度進めること
        await model.connectField()
        let second = model.pairing
        #expect(second != nil)
        #expect(second !== first)
        model.cancelPairing()
    }

    @Test func cancelPairingWithStaleTargetKeepsNewPairing() async {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":600}"#
                )
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let (model, _, defaults, suiteName) = makeModelWithTransport(transport)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.address = "http://127.0.0.1:3000"

        await model.connectField()
        let first = model.pairing
        #expect(first != nil)

        await model.connectField()
        let second = model.pairing
        #expect(second != nil)
        #expect(second !== first)

        // 前の PairView の onDisappear が遅れて届いても、新しいペアリングは消さない
        model.cancelPairing(first)
        #expect(model.pairing === second)
        model.cancelPairing()
    }

    @Test func pairingSuccessTransitionsToConnectedAndIgnoresLateCancel() async {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":1}"#
                )
            }
            if request.url?.path.hasSuffix("api/device/token") == true {
                return reply(request, 200, #"{"token":"denpa_paired","tokenType":"Bearer"}"#)
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let (model, tokens, defaults, suiteName) = makeModelWithTransport(transport)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.address = "http://127.0.0.1:3000"

        await model.connectField()
        let active = model.pairing
        #expect(active != nil)

        for _ in 0..<200 where model.server == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.pairing == nil)
        #expect(model.phase == .connected)
        #expect(model.server?.token == "denpa_paired")
        #expect(tokens.saved[URL(string: "http://127.0.0.1:3000")!] == "denpa_paired")
        #expect(defaults.string(forKey: "serverURL") == "http://127.0.0.1:3000")

        // メイン画面へ切り替わるときに PairView の onDisappear が走っても接続を壊さない
        model.cancelPairing(active)
        model.cancelPairing()
        #expect(model.phase == .connected)
        #expect(model.server?.token == "denpa_paired")
    }

    @Test func lateTokenAfterCancelPairingDoesNotConnect() async {
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let tokenRequested = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":1}"#
                )
            }
            if request.url?.path.hasSuffix("api/device/token") == true {
                tokenRequested.value = true
                await withCheckedContinuation { gate.value = $0 }
                return reply(request, 200, #"{"token":"denpa_late","tokenType":"Bearer"}"#)
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let (model, tokens, defaults, suiteName) = makeModelWithTransport(transport)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        model.address = "http://127.0.0.1:3000"

        await model.connectField()
        for _ in 0..<200 where !tokenRequested.value {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(tokenRequested.value)

        model.cancelPairing()
        gate.value?.resume()
        gate.value = nil
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.pairing == nil)
        #expect(model.server == nil)
        #expect(tokens.saved.isEmpty)
    }
}
