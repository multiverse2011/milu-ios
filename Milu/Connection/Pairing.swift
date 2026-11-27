import Foundation
import Observation
import UIKit

/// `POST api/device/token` の 1 回ぶんの答え。
nonisolated enum PairingPoll: Equatable, Sendable {
    case token(String)
    case pending
    /// 急ぎすぎ。間隔を 5 秒延ばす (4.2)
    case slowDown
    case expired
    case invalidGrant
    case tooManyPending
    /// 5xx。訪ね続ける
    case serverError
    case failure(String)

    nonisolated static func read(status: Int, body: Data) -> PairingPoll {
        if status == 200 {
            if let token = (try? JSONDecoder().decode(DeviceToken.self, from: body))?.token {
                return .token(token)
            }
            return .failure(String(localized: "denpa からの応答を読み取れませんでした"))
        }
        if status >= 500 { return .serverError }
        let response = try? JSONDecoder().decode(ErrorResponse.self, from: body)
        switch response?.errorCode {
        case .tooManyPending: return .tooManyPending
        case .authorizationPending: return .pending
        case .slowDown: return .slowDown
        case .expiredToken: return .expired
        case .invalidGrant: return .invalidGrant
        default:
            return .failure(response?.message ?? String(localized: "ペアリングできません (\(status))"))
        }
    }
}

/// ペアリングの待ち受け (4.2)。QR とコードを出し、`interval` 秒おきに `device/token` を訊く。
@Observable
@MainActor
final class PairingModel: Hashable {
    // navigationDestination(item:) の同一性判定用
    nonisolated static func == (lhs: PairingModel, rhs: PairingModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    let serverURL: URL
    private(set) var code: DeviceCode?
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private let transport: any HTTPTransport
    private let onPaired: @MainActor (ServerConnection) -> Void
    private let sleep: @Sendable (Duration) async -> Void

    init(
        serverURL: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onPaired: @escaping @MainActor (ServerConnection) -> Void
    ) {
        self.serverURL = serverURL
        self.transport = transport
        self.sleep = sleep
        self.onPaired = onPaired
    }

    /// 3 桁の「電話番号」ではなく端末の名前。40 字まで (api.md)
    var deviceName: String {
        String(UIDevice.current.name.prefix(40))
    }

    /// QR と「この端末で許可する」で開く URL。denpa の根からの相対 (4.2)
    var verificationURL: URL? {
        guard let code else { return nil }
        return URL(string: code.verificationUriComplete, relativeTo: serverURL)?.absoluteURL
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        let client = DenpaClient(baseURL: serverURL, token: nil, transport: transport)
        while !Task.isCancelled {
            guard let issued = await issue(client) else { return }
            code = issued
            let restart = await poll(client, code: issued)
            if !restart { return }
            code = nil
        }
    }

    private func issue(_ client: DenpaClient) async -> DeviceCode? {
        while !Task.isCancelled {
            do {
                let data = try await client.post("api/device/code", body: ["name": deviceName])
                guard !Task.isCancelled else { return nil }
                return try JSONDecoder().decode(DeviceCode.self, from: data)
            } catch let error as DenpaError {
                guard !Task.isCancelled else { return nil }
                if case .http(let status, _) = error, status == 429 {
                    // 許されていないコードを古いものから切らせる。10 秒後に出し直す (4.2)
                    await sleep(.seconds(10))
                    continue
                }
                if case .http(let status, let message) = error, status == 403 {
                    // 公開名の denpa (Caddy の後ろ) は /api/device/* を本文なしの 403 で塞ぐ
                    self.error = message?.isEmpty == false
                        ? message!
                        : String(localized: "この接続先ではペアリングできません。家の Wi-Fi から、192.168.x.x:3000 のような denpa のアドレスで接続してください。")
                    return nil
                }
                self.error = Self.message(error)
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                self.error = String(localized: "ペアリングを開始できません")
                return nil
            }
        }
        return nil
    }

    /// `true` ならコードの発行からやり直す
    private func poll(_ client: DenpaClient, code: DeviceCode) async -> Bool {
        var interval = max(1, code.interval)
        let body = try? JSONEncoder().encode(["deviceCode": code.deviceCode])
        while !Task.isCancelled {
            await sleep(.seconds(interval))
            guard !Task.isCancelled else { return false }
            do {
                let (data, http) = try await client.raw("api/device/token", method: "POST", json: body)
                guard !Task.isCancelled else { return false }
                switch PairingPoll.read(status: http.statusCode, body: data) {
                case .token(let token):
                    onPaired(ServerConnection(url: serverURL, token: token))
                    return false
                case .pending:
                    continue
                case .slowDown:
                    interval += 5
                case .expired, .invalidGrant:
                    return true
                case .tooManyPending:
                    await sleep(.seconds(10))
                case .serverError:
                    continue
                case .failure(let message):
                    self.error = message
                    return false
                }
            } catch let error as DenpaError {
                // 訪ねている間の通信の失敗と 5xx は、止めずに次の interval で訪ね続ける
                if case .network = error { continue }
                if case .http(let status, _) = error, status >= 500 { continue }
                self.error = Self.message(error)
                return false
            } catch {
                continue
            }
        }
        return false
    }

    private static func message(_ error: DenpaError) -> String {
        switch error {
        case .unauthorized: String(localized: "認証が必要です")
        case .invalidToken: String(localized: "認証の有効期限が切れました")
        case .http(_, let message): message ?? String(localized: "denpa と通信できません")
        case .network(let message): String(localized: "denpa と通信できません (\(message))")
        case .decoding: String(localized: "denpa からの応答を読み取れませんでした")
        }
    }
}
