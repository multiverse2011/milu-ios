import Foundation

/// デモモードの接続先と通信の差し替え入口。
/// ネットワークへは一切出ず、アプリ内の固定データと動画だけで応答する。
nonisolated enum DemoServer {
    static let scheme = "milu-demo"
    static let url = URL(string: "milu-demo://demo")!
    static var displayName: String { String(localized: "デモ") }
    static var unavailableMessage: String { String(localized: "デモでは使えません") }
    static let connection = ServerConnection(url: url, token: nil)

    static func isDemo(_ url: URL?) -> Bool {
        url?.scheme == scheme
    }

    static let transport: any HTTPTransport = DemoTransport()
    static let sseTransport: any SSETransport = DemoSSETransport()
}

/// デモ用の `HTTPTransport`。`DenpaClient` の下に入り、API の JSON をメモリから返す。
nonisolated struct DemoTransport: HTTPTransport {
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let method = request.httpMethod ?? "GET"
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = queryItems(of: url)
        let current = now()

        if method == "POST" {
            // 再生終了時の視聴位置送信とログアウトはエラーにせず空で受ける
            if parts.count == 4, parts[0] == "api", parts[1] == "recordings", parts[3] == "resume" {
                return response(url: url, status: 204, data: Data())
            }
            if parts == ["api", "device", "logout"] {
                return response(url: url, status: 204, data: Data())
            }
            return unavailable(url: url)
        }

        if method != "GET" {
            return unavailable(url: url)
        }

        switch parts {
        case ["api", "services"]:
            return response(url: url, status: 200, data: DemoData.servicesJSON(now: current))

        case ["api", "playback", "options"]:
            return response(url: url, status: 200, data: DemoData.playbackOptionsJSON())

        case ["api", "search"]:
            let word = query["q"] ?? ""
            let limit = query["limit"].flatMap(Int.init) ?? SearchModel.limit
            return response(
                url: url,
                status: 200,
                data: DemoData.searchJSON(query: word, limit: limit, now: current)
            )

        case ["api", "programs"]:
            let type = query["type"] ?? "GR"
            let range = GuideLayout.broadcastRange(for: GuideLayout.broadcastDay(for: current))
            let from = query["from"].flatMap(Int64.init) ?? range.from
            let to = query["to"].flatMap(Int64.init) ?? range.to
            return response(
                url: url,
                status: 200,
                data: DemoData.guideJSON(type: type, from: from, to: to, now: current)
            )

        case let p where p.count == 3 && p[0] == "api" && p[1] == "programs":
            guard let id = Int64(p[2]), let data = DemoData.programDetailJSON(id: id, now: current) else {
                return notFound(url: url)
            }
            return response(url: url, status: 200, data: data)

        case ["api", "recordings"]:
            let limit = query["limit"].flatMap(Int.init) ?? 50
            let offset = query["offset"].flatMap(Int.init) ?? 0
            return response(
                url: url,
                status: 200,
                data: DemoData.recordingsJSON(limit: limit, offset: offset, now: current)
            )

        case let p where p.count == 3 && p[0] == "api" && p[1] == "recordings":
            guard let id = Int64(p[2]), let data = DemoData.recordingStatusJSON(id: id) else {
                return notFound(url: url)
            }
            return response(url: url, status: 200, data: data)

        case let p where p.count == 4 && p[0] == "api" && p[1] == "recordings" && p[3] == "detail":
            guard let id = Int64(p[2]), let data = DemoData.recordingDetailJSON(id: id) else {
                return notFound(url: url)
            }
            return response(url: url, status: 200, data: data)

        case let p where p.count == 4 && p[0] == "api" && p[1] == "recordings" && p[3] == "playback":
            guard let id = Int64(p[2]), let data = DemoData.recordingPlaybackJSON(id: id) else {
                return notFound(url: url)
            }
            return response(url: url, status: 200, data: data)

        case let p where p.count == 4 && p[0] == "api" && p[1] == "recordings" && p[3] == "chapters":
            guard let id = Int64(p[2]), let data = DemoData.recordingChaptersJSON(id: id) else {
                return notFound(url: url)
            }
            return response(url: url, status: 200, data: data)

        default:
            return notFound(url: url)
        }
    }

    private func queryItems(of url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var out: [String: String] = [:]
        for item in items {
            if let value = item.value {
                out[item.name] = value
            }
        }
        return out
    }

    private func unavailable(url: URL) -> (Data, HTTPURLResponse) {
        let data = DemoData.jsonData(["message": DemoServer.unavailableMessage])
        return response(url: url, status: 400, data: data)
    }

    private func notFound(url: URL) -> (Data, HTTPURLResponse) {
        let data = DemoData.jsonData(["message": String(localized: "見つかりません")])
        return response(url: url, status: 404, data: data)
    }

    private func response(url: URL, status: Int, data: Data) -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, http)
    }
}

/// デモ用の `SSETransport`。ネットワークに出ず、接続が開いた状態を保つ。
nonisolated struct DemoSSETransport: SSETransport {
    func stream(for request: URLRequest) async throws -> SSEStream {
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            continuation.yield(": demo")
        }
        return SSEStream(status: 200, lines: lines)
    }
}
