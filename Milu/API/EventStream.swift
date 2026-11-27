import Foundation

nonisolated struct SSEEvent: Equatable, Sendable {
    let event: String
    let data: String
}

/// SSE の行を `event:` と `data:` に組む (4.3)。塊の境目は呼ぶ側の行読みが吸収する。
nonisolated struct SSEParser {
    private var event = ""
    private var data: [String] = []

    mutating func consume(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            let name = event.isEmpty ? "message" : event
            let body = data.joined(separator: "\n")
            event = ""
            data = []
            return body.isEmpty ? nil : SSEEvent(event: name, data: body)
        }
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

/// `api/events` の応答。テストで差し替えられるようにする。
nonisolated struct SSEStream: Sendable {
    var status: Int
    var lines: AsyncThrowingStream<String, any Error>
}

nonisolated protocol SSETransport: Sendable {
    func stream(for request: URLRequest) async throws -> SSEStream
}

nonisolated struct URLSessionSSETransport: SSETransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stream(for request: URLRequest) async throws -> SSEStream {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return SSEStream(status: status, lines: lines)
    }
}

/// `GET api/events` (4.3)。MainActor で行を組み、切れたら待ちを伸ばして繋ぎ直す。
/// 60 秒の無通信は `URLRequest.timeoutInterval` が見張る (応答開始後も、次のデータまでの間隔で切れることを確認済み)。
@MainActor
final class EventStream {
    private enum Outcome {
        case closed
        case failed
        case auth(ErrorCode?)
        case stopped
    }

    private let baseURL: URL
    private let token: String?
    private let transport: any SSETransport
    private let sleep: @Sendable (Duration) async -> Void
    private let onEvent: (SSEEvent) -> Void
    private let onReconnect: () -> Void
    private let onAuthProblem: (ErrorCode?) -> Void
    private var reconnect = PlaybackRules.ReconnectTimer()
    private var task: Task<Void, Never>?

    init(
        baseURL: URL,
        token: String?,
        transport: any SSETransport = URLSessionSSETransport(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onEvent: @escaping (SSEEvent) -> Void,
        onReconnect: @escaping () -> Void,
        onAuthProblem: @escaping (ErrorCode?) -> Void
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.sleep = sleep
        self.onEvent = onEvent
        self.onReconnect = onReconnect
        self.onAuthProblem = onAuthProblem
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            switch await connectOnce() {
            case .closed, .failed:
                guard !Task.isCancelled else { return }
                onReconnect()
                await sleep(.seconds(reconnect.advance()))
            case .auth, .stopped:
                return
            }
        }
    }

    private func connectOnce() async -> Outcome {
        var request = URLRequest(url: baseURL.appending(path: "api/events"))
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let stream = try await transport.stream(for: request)
            if stream.status == 200 {
                var parser = SSEParser()
                do {
                    for try await line in stream.lines {
                        if Task.isCancelled { return .stopped }
                        // 行が届いている間は待ちを 1 秒に戻す (200 でもすぐ閉じる相手は伸ばす)
                        reconnect.reset()
                        if let event = parser.consume(line: line) {
                            onEvent(event)
                        }
                    }
                    return .closed
                } catch {
                    return .failed
                }
            }
            if stream.status == 401 {
                var body = Data()
                do {
                    for try await line in stream.lines {
                        body.append(Data(line.utf8))
                    }
                } catch {
                    // 本文が読めなくても 401 は 401
                }
                let code = DenpaClient.errorResponse(body)?.errorCode
                onAuthProblem(code)
                return .auth(code)
            }
            // ほかの状態は本文を読み捨てて、待って試し直す
            do {
                for try await _ in stream.lines {}
            } catch {
                return .failed
            }
            return .failed
        } catch {
            return .failed
        }
    }
}
