import Foundation

/// 繋いだ denpa。トークンは家の LAN でログイン無しなら nil (4.2)。
nonisolated struct ServerConnection: Equatable, Sendable {
    let url: URL
    let token: String?

    /// 設定に出す `ホスト:ポート` (デモ中は「デモ」)
    var displayName: String {
        if DemoServer.isDemo(url) { return DemoServer.displayName }
        let host = url.host ?? url.absoluteString
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    var host: String { url.host ?? "" }
}

nonisolated enum ConnectionOutcome: Equatable, Sendable {
    case connected(ServerConnection)
    /// denpa だがログインが要る。QR とコードを出してペアリングする
    case needsPairing(ServerConnection)
    /// 403。この denpa はログインの方法を設定していない (4.2)
    case loginNotConfigured
    case notFound
    case invalidAddress(String)
}

/// 4.2 の流れ。候補の URL を順に試し、200 の局の配列か 401 unauthorized で denpa とみなす。
nonisolated struct ConnectionService: Sendable {
    private enum Probe: Equatable {
        case ok
        case unauthorized
        case invalidToken
        case forbidden
        case notDenpa
        case network
    }

    var transport: any HTTPTransport = URLSessionTransport()
    /// 初めての接続はローカルネットワークの許可待ちで失敗することがあるので、2 秒後に 1 度だけ試し直す (4.2)
    var retryDelay: Duration = .seconds(2)
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// invalid_token のときに Keychain から消す
    var onInvalidToken: @Sendable (URL) -> Void = { _ in }

    func connect(input: String, tokenFor: @Sendable (URL) -> String?) async -> ConnectionOutcome {
        let candidates: [ServerAddressCandidate]
        do {
            candidates = try ServerAddress.candidates(input)
        } catch {
            return .invalidAddress(error.message)
        }

        if let outcome = await attempt(candidates, tokenFor: tokenFor) { return outcome }

        // ローカルネットワークの許可待ちで全部の候補が通信のエラーになったときだけ、2 秒後にもう一巡する (4.2)
        await sleep(retryDelay)
        if let outcome = await attempt(candidates, tokenFor: tokenFor) { return outcome }
        return .notFound
    }

    /// nil は「候補がすべて通信のエラー」。2 秒後にもう一巡する合図
    private func attempt(
        _ candidates: [ServerAddressCandidate],
        tokenFor: @Sendable (URL) -> String?
    ) async -> ConnectionOutcome? {
        var allNetwork = true
        for candidate in candidates {
            guard let url = candidate.url else {
                allNetwork = false
                continue
            }
            var token = tokenFor(url)
            var probe = await send(url: url, token: token)

            if probe == .invalidToken {
                // トークンを消して、トークン無しで呼び直す (4.2)
                onInvalidToken(url)
                token = nil
                probe = await send(url: url, token: nil)
            }

            switch probe {
            case .ok:
                return .connected(ServerConnection(url: url, token: token))
            case .unauthorized:
                return .needsPairing(ServerConnection(url: url, token: nil))
            case .forbidden:
                return .loginNotConfigured
            case .invalidToken:
                // トークン無しでも invalid_token なら、ペアリングからやり直す
                onInvalidToken(url)
                return .needsPairing(ServerConnection(url: url, token: nil))
            case .notDenpa:
                allNetwork = false
            case .network:
                break
            }
        }
        return allNetwork ? nil : .notFound
    }

    private func send(url: URL, token: String?) async -> Probe {
        let client = DenpaClient(baseURL: url, token: token, transport: transport)
        do {
            let (data, http) = try await client.raw("api/services")
            switch http.statusCode {
            case 200:
                return DenpaClient.isServiceList(data) ? .ok : .notDenpa
            case 401:
                switch DenpaClient.errorCode(data) {
                case "authorization_pending", "unauthorized": return .unauthorized
                case "invalid_token": return .invalidToken
                default: return .notDenpa
                }
            case 403:
                return .forbidden
            default:
                return .notDenpa
            }
        } catch let error as DenpaError {
            if case .network = error { return .network }
            return .notDenpa
        } catch {
            return .network
        }
    }
}
