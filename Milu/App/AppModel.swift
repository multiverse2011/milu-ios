import Foundation
import Observation

/// 接続の状態 (5 節)。接続前は繋ぐ画面、繋いだらタブを出す。
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
    }

    enum Failure: Equatable {
        /// 「denpa が見つかりません」と案内 (3.5)
        case notFound
        /// 欄の下に出す 1 行 (https で繋いでください・ログインの方法未設定など)
        case message(String)
    }

    /// PR 3 以降の画面が使う API の失敗。401 はトークンを捨てて呼び直し、それでもだめならペアリングへ戻す (4.2)
    enum APIError: Error, Equatable {
        case notConnected
        case needsPairing
        case http(status: Int, message: String?)
        case network(String)
        case decoding
    }

    private static let serverKey = "serverURL"

    private(set) var phase: Phase = .idle
    private(set) var server: ServerConnection?
    private(set) var pairing: PairingModel?
    /// 「ライブで観る」の求め (3.5)。ライブのタブへ移ってこの局を映す。映す側は PR 3 が受け取る。
    struct LiveWatchRequest: Equatable, Sendable {
        let serviceID: Int64
        /// 同じ局をもう一度求めても画面が気づけるよう、求めごとに別の値にする
        let nonce = UUID()
    }
    private(set) var liveWatch: LiveWatchRequest?
    var address = ""
    var failure: Failure?

    /// 番組表の「ライブで観る」から。タブの切り替えは MainTabView が見てやる。
    func requestLiveWatch(serviceID: Int64) {
        liveWatch = LiveWatchRequest(serviceID: serviceID)
    }

    /// SSE の受け手を外すための持ち手。画面が閉じるときに `cancel` する (4.3)
    @MainActor
    final class Subscription {
        private var remove: (() -> Void)?

        init(_ remove: @escaping () -> Void) {
            self.remove = remove
        }

        func cancel() {
            remove?()
            remove = nil
        }
    }

    private var eventHandlers: [UUID: (SSEEvent) -> Void] = [:]
    private var reconnectHandlers: [UUID: () -> Void] = [:]

    private var service: ConnectionService
    private let tokens: any TokenStore
    private let defaults: UserDefaults
    private let startsEvents: Bool
    private let transport: any HTTPTransport
    private var events: EventStream?

    init(
        service: ConnectionService = ConnectionService(),
        keychain: any TokenStore = Keychain(),
        defaults: UserDefaults = .standard,
        startsEvents: Bool = true,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.tokens = keychain
        self.defaults = defaults
        self.startsEvents = startsEvents
        self.transport = transport
        var service = service
        service.onInvalidToken = { url in keychain.delete(for: url) }
        self.service = service

        if let stored = defaults.string(forKey: Self.serverKey), !stored.isEmpty {
            address = DemoServer.isDemo(URL(string: stored)) ? "" : stored
            if let url = URL(string: stored), url.scheme != nil, url.host != nil {
                // 起動時は確かめの通信をしない。覚えた接続先とトークンでそのままタブを出す (3.5)
                let connection = ServerConnection(url: url, token: keychain.load(for: url))
                server = connection
                address = DemoServer.isDemo(url) ? "" : connection.displayName
                phase = .connected
                if startsEvents { startEvents() }
            }
        }
    }

    var isConnecting: Bool { phase == .connecting }
    var hasToken: Bool { server?.token != nil }
    var isDemo: Bool { DemoServer.isDemo(server?.url) }

    /// 接続画面の「デモで試す」。通信やペアリングをせず、アプリ内の固定データへ繋ぐ。
    func startDemo() {
        pairing?.cancel()
        pairing = nil
        liveWatch = nil
        connect(DemoServer.connection)
    }

    /// SSE の通知を受ける。返した持ち手を `cancel` するまで受ける (ライブ・番組表・録画が足す)
    func addEventListener(_ handler: @escaping (SSEEvent) -> Void) -> Subscription {
        let id = UUID()
        eventHandlers[id] = handler
        return Subscription { [weak self] in self?.eventHandlers[id] = nil }
    }

    /// SSE が繋ぎ直ったときに読み直す
    func addReconnectListener(_ handler: @escaping () -> Void) -> Subscription {
        let id = UUID()
        reconnectHandlers[id] = handler
        return Subscription { [weak self] in self?.reconnectHandlers[id] = nil }
    }

    // MARK: - PR 3 以降の画面が使う API (4.2 の 401 をここで 1 度だけ扱う)

    func get(_ path: String) async throws -> Data {
        try await request(method: "GET", path: path, json: nil)
    }

    func post(_ path: String, json: Data? = nil) async throws -> Data {
        try await request(method: "POST", path: path, json: json)
    }

    func delete(_ path: String) async throws -> Data {
        try await request(method: "DELETE", path: path, json: nil)
    }

    /// 接続先の画面で「繋ぎ直す」。成功したら接続先を替え、失敗したら元のまま理由を返す (3.5)
    func reconnect(_ input: String) async -> String? {
        let outcome = await run(input)
        switch outcome {
        case .connected(let connection):
            connect(connection)
            return nil
        case .needsPairing(let connection):
            startPairing(connection)
            return nil
        case .loginNotConfigured:
            return String(localized: "この denpa にはログイン方法が設定されていないため接続できません")
        case .notFound:
            return String(localized: "denpa が見つかりません")
        case .invalidAddress(let message):
            return message
        }
    }

    func connectField() async {
        await connect(address)
    }

    func cancelPairing(_ target: PairingModel? = nil) {
        if let target, pairing !== target { return }
        pairing?.cancel()
        pairing = nil
    }

    /// ライブのストリームが invalid_token を返したとき (4.2)
    func discardToken(for url: URL) {
        guard server?.url == url else { return }
        tokens.delete(for: url)
        server = ServerConnection(url: url, token: nil)
    }

    /// ライブのストリームが unauthorized を返したとき (4.2)
    func requirePairing(for url: URL) {
        guard server?.url == url else { return }
        beginPairing(url)
    }

    /// 「サーバーから外す」。logout が失敗してもトークンは消す (3.5)。
    /// 先に接続を切るので、遅れて返った 401 でサーバーが復活することはない。
    func signOut() async {
        guard let server else { return }
        let url = server.url
        let token = server.token
        let wasDemo = DemoServer.isDemo(url)
        events?.stop()
        events = nil
        pairing?.cancel()
        pairing = nil
        self.server = nil
        phase = .idle
        failure = nil
        tokens.delete(for: url)
        defaults.removeObject(forKey: Self.serverKey)
        if wasDemo {
            clearDemoState()
            address = ""
        }

        if let token, !wasDemo {
            let client = DenpaClient(baseURL: url, token: token, transport: transport)
            _ = try? await client.post("api/device/logout")
        }
    }

    /// 裏に回ったら SSE を閉じ、戻ったら繋ぎ直す (3.3)
    func setActive(_ active: Bool) {
        guard active else {
            events?.stop()
            events = nil
            return
        }
        if startsEvents, server != nil { startEvents() }
    }

    private func request(method: String, path: String, json: Data?) async throws -> Data {
        guard let current = server else { throw APIError.notConnected }
        do {
            return try await call(current.url, token: current.token, method: method, path: path, json: json)
        } catch DenpaError.invalidToken {
            // 「サーバーから外す」の後に遅れて返った応答では、サーバーを復活させない
            guard server?.url == current.url else { throw APIError.notConnected }
            // トークンを消して、トークン無しで呼び直す (4.2)
            tokens.delete(for: current.url)
            server = ServerConnection(url: current.url, token: nil)
            do {
                return try await call(current.url, token: nil, method: method, path: path, json: json)
            } catch DenpaError.unauthorized {
                guard server?.url == current.url else { throw APIError.notConnected }
                beginPairing(current.url)
                throw APIError.needsPairing
            } catch DenpaError.invalidToken {
                guard server?.url == current.url else { throw APIError.notConnected }
                beginPairing(current.url)
                throw APIError.needsPairing
            } catch let error as DenpaError {
                throw map(error)
            }
        } catch DenpaError.unauthorized {
            guard server?.url == current.url else { throw APIError.notConnected }
            beginPairing(current.url)
            throw APIError.needsPairing
        } catch let error as DenpaError {
            throw map(error)
        }
    }

    private func call(_ url: URL, token: String?, method: String, path: String, json: Data?) async throws -> Data {
        let active: any HTTPTransport = DemoServer.isDemo(url) ? DemoServer.transport : transport
        return try await DenpaClient(baseURL: url, token: token, transport: active)
            .send(path, method: method, json: json)
    }

    private func map(_ error: DenpaError) -> APIError {
        switch error {
        case .unauthorized, .invalidToken:
            .needsPairing
        case .http(let status, let message):
            .http(status: status, message: message)
        case .network(let message):
            .network(message)
        case .decoding:
            .decoding
        }
    }

    private func beginPairing(_ url: URL) {
        tokens.delete(for: url)
        if server?.url == url {
            server = ServerConnection(url: url, token: nil)
        }
        startPairing(ServerConnection(url: url, token: nil))
    }

    private func connect(_ input: String) async {
        phase = .connecting
        failure = nil
        let outcome = await run(input)
        switch outcome {
        case .connected(let connection):
            connect(connection)
        case .needsPairing(let connection):
            phase = .idle
            startPairing(connection)
        case .loginNotConfigured:
            phase = .idle
            failure = .message(String(localized: "この denpa にはログイン方法が設定されていないため接続できません"))
        case .notFound:
            phase = .idle
            failure = .notFound
        case .invalidAddress(let message):
            phase = .idle
            failure = .message(message)
        }
    }

    private func run(_ input: String) async -> ConnectionOutcome {
        let tokens = tokens
        return await service.connect(input: input) { url in
            tokens.load(for: url)
        }
    }

    private func connect(_ connection: ServerConnection) {
        let wasDemo = isDemo
        let nextDemo = DemoServer.isDemo(connection.url)
        if wasDemo, !nextDemo {
            clearDemoState()
        }
        server = connection
        phase = .connected
        failure = nil
        address = nextDemo ? "" : connection.displayName
        defaults.set(connection.url.absoluteString, forKey: Self.serverKey)
        if startsEvents { startEvents() }
    }

    private func clearDemoState() {
        defaults.removeObject(forKey: "lastServiceID")
        liveWatch = nil
    }

    private func startPairing(_ connection: ServerConnection) {
        // 古いモデルの遅れた応答が新しいペアリングを乗っ取らないよう、差し替える前に必ず止める
        pairing?.cancel()
        let model = PairingModel(serverURL: connection.url, transport: transport) { [weak self] paired in
            guard let self, self.pairing != nil else { return }
            self.paired(paired)
        }
        pairing = model
        model.start()
    }

    private func paired(_ connection: ServerConnection) {
        if let token = connection.token {
            tokens.save(token, for: connection.url)
        }
        pairing = nil
        connect(connection)
    }

    private func startEvents() {
        events?.stop()
        guard let server else { return }
        let sse: any SSETransport = DemoServer.isDemo(server.url) ? DemoServer.sseTransport : URLSessionSSETransport()
        let stream = EventStream(
            baseURL: server.url,
            token: server.token,
            transport: sse,
            onEvent: { [weak self] event in
                guard let self else { return }
                for handler in self.eventHandlers.values { handler(event) }
            },
            onReconnect: { [weak self] in
                guard let self else { return }
                for handler in self.reconnectHandlers.values { handler() }
            },
            onAuthProblem: { [weak self] code in self?.handleEventAuth(code) }
        )
        events = stream
        stream.start()
    }

    /// SSE の 401 も、API と同じ決まりに渡す (4.2)
    private func handleEventAuth(_ code: ErrorCode?) {
        guard let server else { return }
        switch code {
        case .invalidToken:
            tokens.delete(for: server.url)
            self.server = ServerConnection(url: server.url, token: nil)
            startEvents()
        default:
            beginPairing(server.url)
        }
    }
}

#if DEBUG
extension AppModel {
    static let uiTestDemoArgument = "-MiluUITestDemo"

    /// UI テスト用の起動口 (DEBUG のみ)。
    /// `-MiluUITestDemo` があるときは接続先とトークンだけを専用領域に隔離し、毎回デモから始める (画面のモデルは `.standard` を使う)。
    static func makeForLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        keychain: any TokenStore = Keychain(),
        defaults: UserDefaults = .standard,
        startsEvents: Bool = true
    ) -> AppModel {
        guard arguments.contains(uiTestDemoArgument) else {
            return AppModel(
                keychain: keychain,
                defaults: defaults,
                startsEvents: startsEvents
            )
        }
        let suiteName = "com.ayushio.milu.uitest"
        let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? defaults
        if isolatedDefaults !== defaults {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }
        let model = AppModel(
            keychain: NoopTokenStore(),
            defaults: isolatedDefaults,
            startsEvents: startsEvents
        )
        model.startDemo()
        return model
    }
}

private nonisolated struct NoopTokenStore: TokenStore, Sendable {
    func load(for url: URL) -> String? { nil }
    func save(_ token: String, for url: URL) {}
    func delete(for url: URL) {}
}
#endif
