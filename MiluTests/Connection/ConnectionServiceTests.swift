import Foundation
import Testing
@testable import Milu

@Suite struct ConnectionServiceTests {
    private func service(_ transport: StubTransport, sleeps: Box<Int>? = nil) -> ConnectionService {
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in
            if let sleeps { sleeps.value += 1 }
        }
        return service
    }

    @Test func serviceListConnectsWithoutToken() async {
        let transport = StubTransport { request in reply(request, 200, "[]") }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .connected(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
    }

    @Test func unauthorizedNeedsPairing() async {
        let transport = StubTransport { request in
            reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .needsPairing(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
    }

    @Test func forbiddenMeansLoginIsNotConfigured() async {
        let transport = StubTransport { request in reply(request, 403, "") }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .loginNotConfigured)
    }

    @Test func invalidTokenIsDeletedAndRetriedWithoutIt() async {
        let deleted = Box<[URL]>([])
        let transport = StubTransport { request in
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return reply(request, 401, #"{"error":"invalid_token"}"#)
            }
            return reply(request, 200, "[]")
        }
        var service = service(transport)
        service.onInvalidToken = { url in deleted.value = deleted.value + [url] }
        let outcome = await service.connect(input: "http://127.0.0.1:3000", tokenFor: { _ in "old" })
        #expect(outcome == .connected(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
        #expect(deleted.value == [URL(string: "http://127.0.0.1:3000")!])
    }

    @Test func portFallsBackTo3000() async {
        let transport = StubTransport { request in
            request.url?.port == 3000 ? reply(request, 200, "[]") : reply(request, 404, "")
        }
        let outcome = await service(transport).connect(input: "127.0.0.1", tokenFor: { _ in nil })
        #expect(outcome == .connected(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
        #expect(transport.requests.map(\.url?.port) == [80, 3000])
    }

    @Test func networkErrorIsRetriedOnce() async {
        let attempts = Box(0)
        let transport = StubTransport { request in
            if attempts.value == 0 {
                attempts.value = 1
                throw URLError(.timedOut)
            }
            return reply(request, 200, "[]")
        }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .connected(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
        #expect(attempts.value == 1)
    }

    @Test func networkErrorTwiceIsNotFound() async {
        let transport = StubTransport { _ in throw URLError(.timedOut) }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .notFound)
    }

    @Test func allNetworkRetriesAllCandidatesOnce() async {
        let calls = Box<[Int]>([])
        let sleeps = Box(0)
        let transport = StubTransport { request in
            let port = request.url?.port ?? 0
            calls.value = calls.value + [port]
            if calls.value.count == 4 {
                return reply(request, 200, "[]")
            }
            throw URLError(.timedOut)
        }
        let outcome = await service(transport, sleeps: sleeps).connect(input: "127.0.0.1", tokenFor: { _ in nil })
        #expect(outcome == .connected(ServerConnection(url: URL(string: "http://127.0.0.1:3000")!, token: nil)))
        #expect(calls.value == [80, 3000, 80, 3000])
        #expect(sleeps.value == 1)
    }

    @Test func nonNetworkCandidateSkipsSecondRound() async {
        let sleeps = Box(0)
        let transport = StubTransport { request in
            if request.url?.port == 3000 {
                return reply(request, 404, "")
            }
            throw URLError(.timedOut)
        }
        let outcome = await service(transport, sleeps: sleeps).connect(input: "127.0.0.1", tokenFor: { _ in nil })
        #expect(outcome == .notFound)
        #expect(transport.requests.map(\.url?.port) == [80, 3000])
        #expect(sleeps.value == 0)
    }

    @Test func htmlIsNotDenpa() async {
        let transport = StubTransport { request in reply(request, 200, "<html></html>") }
        let outcome = await service(transport).connect(input: "http://127.0.0.1:3000", tokenFor: { _ in nil })
        #expect(outcome == .notFound)
    }

    @Test func outsideHttpIsRejectedBeforeSending() async {
        let transport = StubTransport { request in reply(request, 200, "[]") }
        let outcome = await service(transport).connect(input: "http://example.com", tokenFor: { _ in nil })
        #expect(outcome == .invalidAddress("ローカルネットワーク外からは HTTPS で接続してください"))
        #expect(transport.requests.isEmpty)
    }
}
