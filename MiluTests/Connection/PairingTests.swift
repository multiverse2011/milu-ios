import Foundation
import Testing
@testable import Milu

@Suite struct PairingTests {
    @Test func deviceCodeDecodes() throws {
        let json = #"""
        {
          "deviceCode": "device-1",
          "userCode": "ABCD-EFGH",
          "verificationUri": "device",
          "verificationUriComplete": "device?code=ABCD-EFGH",
          "expiresIn": 600,
          "interval": 5
        }
        """#
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(json.utf8))
        #expect(code.userCode == "ABCD-EFGH")
        #expect(code.verificationUriComplete == "device?code=ABCD-EFGH")
        #expect(code.interval == 5)
    }

    @Test func tokenSucceeds() {
        let poll = PairingPoll.read(
            status: 200,
            body: Data(#"{"token":"denpa_abc","tokenType":"Bearer"}"#.utf8)
        )
        #expect(poll == .token("denpa_abc"))
    }

    @Test func pollingErrorsAreDistinguished() {
        #expect(PairingPoll.read(status: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)) == .pending)
        #expect(PairingPoll.read(status: 400, body: Data(#"{"error":"slow_down"}"#.utf8)) == .slowDown)
        #expect(PairingPoll.read(status: 400, body: Data(#"{"error":"expired_token"}"#.utf8)) == .expired)
        #expect(PairingPoll.read(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)) == .invalidGrant)
        #expect(PairingPoll.read(status: 429, body: Data(#"{"error":"too_many_pending"}"#.utf8)) == .tooManyPending)
        #expect(PairingPoll.read(status: 500, body: Data()) == .serverError)
    }

    @Test func unknownErrorKeepsMessage() {
        #expect(
            PairingPoll.read(status: 403, body: Data(#"{"message":"だめです"}"#.utf8))
                == .failure("だめです")
        )
    }
}


private enum FakeTokenResponse {
    case http(Int, String)
    case network
}

nonisolated func deviceCodeJSON(interval: Int) -> String {
    #"{"deviceCode":"d","userCode":"ABCD-EFGH","verificationUri":"device","verificationUriComplete":"device?code=ABCD-EFGH","expiresIn":600,"interval":"# + "\(interval)}"
}

extension PairingTests {
    private func start(
        _ responses: [FakeTokenResponse],
        codeStatuses: [Int] = [200],
        onPaired: @escaping @MainActor (ServerConnection) -> Void,
        sleeps: Box<[Duration]>,
        codes: Box<Int>,
        tokenIndex: Box<Int>
    ) -> PairingModel {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                let codeStatus = codeStatuses[min(codes.value, codeStatuses.count - 1)]
                codes.value += 1
                if codeStatus != 200 { return reply(request, codeStatus, #"{"error":"too_many_pending"}"#) }
                return reply(request, 200, deviceCodeJSON(interval: 5))
            }
            let index = min(tokenIndex.value, responses.count - 1)
            tokenIndex.value += 1
            switch responses[index] {
            case .http(let code, let body): return reply(request, code, body)
            case .network: throw URLError(.timedOut)
            }
        }
        let model = PairingModel(
            serverURL: URL(string: "http://denpa.lan:3000")!,
            transport: transport,
            sleep: { duration in
                sleeps.value = sleeps.value + [duration]
                await Task.yield()
            },
            onPaired: onPaired
        )
        return model
    }

    @Test func deviceCode403ExplainsThePublicName() async {
        let sleeps = Box<[Duration]>([])
        let codes = Box(0)
        let index = Box(0)
        let model = start(
            [],
            codeStatuses: [403],
            onPaired: { _ in },
            sleeps: sleeps,
            codes: codes,
            tokenIndex: index
        )
        model.start()
        for _ in 0..<100 where model.error == nil {
            await Task.yield()
        }
        #expect(model.error == "この接続先ではペアリングできません。家の Wi-Fi から、192.168.x.x:3000 のような denpa のアドレスで接続してください。")
        #expect(codes.value == 1)
    }

    @Test func pollingFollowsIntervalSlowDownAndRestart() async {
        let sleeps = Box<[Duration]>([])
        let codes = Box(0)
        let index = Box(0)
        let paired = Box<ServerConnection?>(nil)
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let model = start(
            [
                .http(400, #"{"error":"authorization_pending"}"#),
                .http(400, #"{"error":"slow_down"}"#),
                .http(400, #"{"error":"expired_token"}"#),
                .http(200, #"{"token":"denpa_x","tokenType":"Bearer"}"#),
            ],
            onPaired: { connection in
                paired.value = connection
                continuation.yield()
            },
            sleeps: sleeps,
            codes: codes,
            tokenIndex: index
        )
        model.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        #expect(paired.value?.token == "denpa_x")
        #expect(sleeps.value == [.seconds(5), .seconds(5), .seconds(10), .seconds(5)])
        #expect(codes.value == 2)
    }

    @Test func tooManyPendingWaitsTenSeconds() async {
        let sleeps = Box<[Duration]>([])
        let codes = Box(0)
        let index = Box(0)
        let paired = Box<ServerConnection?>(nil)
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let model = start(
            [.http(200, #"{"token":"denpa_x","tokenType":"Bearer"}"#)],
            codeStatuses: [429, 200],
            onPaired: { connection in
                paired.value = connection
                continuation.yield()
            },
            sleeps: sleeps,
            codes: codes,
            tokenIndex: index
        )
        model.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        #expect(paired.value?.token == "denpa_x")
        #expect(sleeps.value == [.seconds(10), .seconds(5)])
        #expect(codes.value == 2)
    }

    @Test func transientTokenErrorsKeepPolling() async {
        let sleeps = Box<[Duration]>([])
        let codes = Box(0)
        let index = Box(0)
        let paired = Box<ServerConnection?>(nil)
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let model = start(
            [
                .network,
                .http(500, ""),
                .http(200, #"{"token":"denpa_x","tokenType":"Bearer"}"#),
            ],
            onPaired: { connection in
                paired.value = connection
                continuation.yield()
            },
            sleeps: sleeps,
            codes: codes,
            tokenIndex: index
        )
        model.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        #expect(paired.value?.token == "denpa_x")
        #expect(sleeps.value == [.seconds(5), .seconds(5), .seconds(5)])
        #expect(model.error == nil)
    }

    @Test func cancelStopsPolling() async throws {
        let sleeps = Box<[Duration]>([])
        let codes = Box(0)
        let index = Box(0)
        let model = start(
            [.http(400, #"{"error":"authorization_pending"}"#)],
            onPaired: { _ in },
            sleeps: sleeps,
            codes: codes,
            tokenIndex: index
        )
        model.start()
        try await Task.sleep(for: .milliseconds(30))
        model.cancel()
        let count = sleeps.value.count
        try await Task.sleep(for: .milliseconds(30))
        // 取り消しの瞬間に走っていた sleep が 1 回だけ残ることはある
        #expect(sleeps.value.count <= count + 1)
    }
}
