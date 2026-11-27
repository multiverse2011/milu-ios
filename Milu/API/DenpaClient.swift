import Foundation

/// 通信を差し替えられるようにする (テスト用)。D11 の `Media/` とは別で、こちらは MainActor の外でよい。
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// denpa の API の失敗。401 は `unauthorized` (ペアリング) と `invalid_token` (トークンを捨てて呼び直す) を分ける (4.2)。
nonisolated enum DenpaError: Error, Equatable {
    case unauthorized
    case invalidToken
    case http(status: Int, message: String?)
    case network(String)
    case decoding
}

/// 接続先・Bearer・401 の見分け・Content-Type を受け持つ (5 節・4.1)。
nonisolated struct DenpaClient: Sendable {
    let baseURL: URL
    let token: String?
    let transport: any HTTPTransport

    init(baseURL: URL, token: String?, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    func url(_ path: String) -> URL {
        // 一覧は `?limit=&offset=` を付ける。`appending(path:)` は ? を道の字として扱うので分ける
        guard let mark = path.firstIndex(of: "?") else {
            return baseURL.appending(path: path)
        }
        let name = String(path[..<mark])
        let query = String(path[path.index(after: mark)...])
        guard var components = URLComponents(
            url: baseURL.appending(path: name),
            resolvingAgainstBaseURL: false
        ) else { return baseURL.appending(path: path) }
        components.percentEncodedQuery = query
        return components.url ?? baseURL.appending(path: path)
    }

    /// 状態をそのまま見たいとき (ペアリングの 400/429 を分ける)。
    func raw(
        _ path: String,
        method: String = "GET",
        json: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        // 書き込みは本文が無くても application/json を付ける (4.1)
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = json
        }
        do {
            return try await transport.send(request)
        } catch {
            throw DenpaError.network(error.localizedDescription)
        }
    }

    /// 状態を見て本文を返す。AppModel の 401 の扱いからも使う
    func send(_ path: String, method: String = "GET", json: Data? = nil) async throws -> Data {
        let response = try await raw(path, method: method, json: json)
        return try check(response)
    }

    func post(_ path: String, body: some Encodable) async throws -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw DenpaError.decoding
        }
        let response = try await raw(path, method: "POST", json: data)
        return try check(response)
    }

    func post(_ path: String) async throws -> Data {
        let response = try await raw(path, method: "POST")
        return try check(response)
    }

    func delete(_ path: String) async throws -> Data {
        let response = try await raw(path, method: "DELETE")
        return try check(response)
    }

    private func check(_ response: (Data, HTTPURLResponse)) throws -> Data {
        let (data, http) = response
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            switch Self.errorCode(data) {
            case "invalid_token": throw DenpaError.invalidToken
            case "unauthorized": throw DenpaError.unauthorized
            default: throw DenpaError.http(status: 401, message: Self.message(data))
            }
        default:
            throw DenpaError.http(status: http.statusCode, message: Self.message(data))
        }
    }

    static func errorResponse(_ data: Data) -> ErrorResponse? {
        try? JSONDecoder().decode(ErrorResponse.self, from: data)
    }

    static func errorCode(_ data: Data) -> String? {
        errorResponse(data)?.error
    }

    static func message(_ data: Data) -> String? {
        errorResponse(data)?.message
    }

    /// `GET api/services` が局の配列を返すか (denpa かどうかの見分け・4.2)
    static func isServiceList(_ data: Data) -> Bool {
        // 配列でも、家の LAN のダッシュボード ([{"name":"Rec","services":[...]}]) は denpa ではない。
        // 空の配列は局が 0 の denpa とみなす。
        // 種別は知らない名前でもよい (知らない種別の局だけの denpa を外さない)
        guard let lossy = try? JSONDecoder().decode([LossyDecodable<ServiceListItem>].self, from: data) else {
            return false
        }
        return lossy.isEmpty || lossy.contains { $0.value != nil }
    }

    private struct ServiceListItem: Decodable {
        var id: Int64
        var name: String
        var type: String
    }
}
