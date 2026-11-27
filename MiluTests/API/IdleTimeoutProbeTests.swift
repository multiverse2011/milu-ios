import Foundation
import Network
import Testing

@Suite struct IdleTimeoutProbeTests {
    @Test func sessionTimesOutOnSilentStream() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = AsyncStream<Void> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    continuation.yield()
                    continuation.finish()
                }
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
                connection.send(content: head, completion: .contentProcessed { _ in
                    connection.send(content: Data("event: ping\ndata: 1\n\n".utf8), completion: .contentProcessed { _ in })
                })
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        let port = try #require(listener.port).rawValue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        let start = Date()
        do {
            let (bytes, _) = try await session.bytes(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/events")!))
            for try await _ in bytes.lines {}
            Issue.record("黙ったまま終わった")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            #expect(Date().timeIntervalSince(start) < 5)
        } catch {
            Issue.record("URLError ではない: \(error)")
        }
    }
}
