import Foundation
import Testing
@testable import Milu

@Suite struct EventStreamTests {
    @Test func reconnectsWithBackoffAndKeepsTheEvent() async {
        let calls = Box(0)
        let transport = StubSSETransport { _ in
            calls.value += 1
            return calls.value == 1
                ? sseStream(200, ["event: ping", "data: 1", ""])
                : sseStream(200, [])
        }
        let sleeps = Box<[Duration]>([])
        let reconnects = Box(0)
        let events = Box<[SSEEvent]>([])
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let stream = EventStream(
            baseURL: URL(string: "http://denpa.lan:3000")!,
            token: nil,
            transport: transport,
            sleep: { duration in
                sleeps.value = sleeps.value + [duration]
                await Task.yield()
            },
            onEvent: { events.value = events.value + [$0] },
            onReconnect: {
                reconnects.value += 1
                continuation.yield()
            },
            onAuthProblem: { _ in }
        )
        stream.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        stream.stop()
        #expect(sleeps.value.prefix(2) == [.seconds(1), .seconds(2)])
        #expect(events.value.first?.event == "ping")
        #expect(reconnects.value >= 3)
    }

    @Test func unauthorizedIsHandedToTheAuthHandler() async {
        let auth = Box<ErrorCode?>(nil)
        let transport = StubSSETransport { _ in
            sseStream(401, [#"{"error":"invalid_token"}"#])
        }
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let stream = EventStream(
            baseURL: URL(string: "http://denpa.lan:3000")!,
            token: "old",
            transport: transport,
            sleep: { _ in await Task.yield() },
            onEvent: { _ in },
            onReconnect: {},
            onAuthProblem: { code in
                auth.value = code
                continuation.yield()
            }
        )
        stream.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        stream.stop()
        #expect(auth.value == .invalidToken)
        #expect(transport.requests.count == 1)
    }

    @Test func failuresBackOff() async {
        let calls = Box(0)
        let transport = StubSSETransport { _ in
            calls.value += 1
            throw URLError(.timedOut)
        }
        let sleeps = Box<[Duration]>([])
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let stream = EventStream(
            baseURL: URL(string: "http://denpa.lan:3000")!,
            token: nil,
            transport: transport,
            sleep: { duration in
                sleeps.value = sleeps.value + [duration]
                continuation.yield()
                await Task.yield()
            },
            onEvent: { _ in },
            onReconnect: {},
            onAuthProblem: { _ in }
        )
        stream.start()
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        stream.stop()
        #expect(sleeps.value.prefix(3) == [.seconds(1), .seconds(2), .seconds(4)])
    }
}
