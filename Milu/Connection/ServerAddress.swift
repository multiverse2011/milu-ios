import Darwin
import Foundation

/// 接続先の候補 1 つ。
struct ServerAddressCandidate: Equatable, Sendable {
    /// "http" / "https"
    var scheme: String
    var host: String
    var port: Int

    nonisolated init(scheme: String, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// 試す URL。IPv6 の名前は `[ ]` で囲む。
    nonisolated var url: URL? {
        let name = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(name):\(port)")
    }
}

enum ServerAddressError: Error, Equatable {
    /// アドレスとして読めない
    case notURL
    /// 家の中でない名前の `http://` (D12)
    case httpsRequired

    /// 欄の下に出す文 (4.2 と、前の版のうち設計書に無いものだけ)
    nonisolated var message: String {
        switch self {
        case .notURL:
            String(localized: "アドレスの形式が正しくありません")
        case .httpsRequired:
            String(localized: "ローカルネットワーク外からは HTTPS で接続してください")
        }
    }
}

/// 4.2 の「URL を入れたとき」の決まり。家の中の判定・スキームの補い・試すポートの順。
enum ServerAddress {
    /// 名前が家の中か。denpa の `indoor` と同じ (4.2)。CGNAT の 100.64/10 は入れない。
    nonisolated static func isIndoor(_ host: String) -> Bool {
        var name = host.lowercased()
        // IPv6 の括弧は外す
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        if name == "localhost" { return true }
        if let v6 = ipv6Bytes(name) {
            if v6 == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }
            return v6[0] & 0xfe == 0xfc
        }
        if let v4 = ipv4Bytes(name) {
            if v4[0] == 127 || v4[0] == 10 { return true }
            if v4[0] == 192 && v4[1] == 168 { return true }
            if v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31 { return true }
            return false
        }
        if !name.contains(".") { return true }
        for suffix in [".local", ".lan", ".home.arpa", ".internal"] where name.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// 入力を解き、試すポートの候補を順に返す (4.2)。
    /// スキームを省いたら家の中なら `http://`、それ以外は `https://`。家の中でない `http://` は受けない。
    /// ポートを省いたら 80 → 3000 の順 (https なら 443 だけ)。パス以降は落とす。
    nonisolated static func candidates(_ input: String) throws(ServerAddressError) -> [ServerAddressCandidate] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .notURL }

        var scheme: String?
        var rest = trimmed
        if let range = trimmed.range(of: "://") {
            let head = trimmed[trimmed.startIndex..<range.lowerBound].lowercased()
            guard head == "http" || head == "https" else { throw .notURL }
            scheme = head
            rest = String(trimmed[range.upperBound...])
        }

        guard let parsed = URLComponents(string: "\(scheme ?? "http")://\(rest)") else {
            throw .notURL
        }
        var host = parsed.host ?? ""
        // IPv6 の括弧は外す
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, !host.contains(" ") else {
            throw .notURL
        }
        let port = parsed.port
        let indoor = isIndoor(host)

        let resolved: String
        if let scheme {
            resolved = scheme
        } else {
            resolved = indoor ? "http" : "https"
        }
        if resolved == "http" && !indoor { throw .httpsRequired }

        if let port {
            return [ServerAddressCandidate(scheme: resolved, host: host, port: port)]
        }
        if resolved == "https" {
            return [ServerAddressCandidate(scheme: resolved, host: host, port: 443)]
        }
        return [
            ServerAddressCandidate(scheme: resolved, host: host, port: 80),
            ServerAddressCandidate(scheme: resolved, host: host, port: 3000),
        ]
    }

    /// "1.2.3.4" を読む。inet_pton と同じく、先頭の 0 や 4 つでない並びは読まない。
    nonisolated static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { inet_pton(AF_INET, host, $0.baseAddress) }
        return ok == 1 ? bytes : nil
    }

    /// IPv6 を 16 バイトに読む。`::` の圧縮と、末尾に IPv4 が埋まった形も inet_pton が読む。
    nonisolated static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ok = bytes.withUnsafeMutableBytes { inet_pton(AF_INET6, host, $0.baseAddress) }
        return ok == 1 ? bytes : nil
    }
}
