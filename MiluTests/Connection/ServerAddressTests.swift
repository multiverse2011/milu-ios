import Foundation
import Testing

@testable import Milu

struct ServerAddressTests {
    @Test(arguments: [
        ("127.0.0.1", true),
        ("127.255.255.255", true),
        ("10.0.0.1", true),
        ("10.255.255.255", true),
        ("172.16.0.1", true),
        ("172.31.255.255", true),
        ("172.15.0.1", false),
        ("172.32.0.1", false),
        ("192.168.1.20", true),
        ("192.167.255.255", false),
        ("100.64.0.1", false), // CGNAT は家の中に入れない (4.2)
        ("100.127.255.255", false),
        ("100.63.255.255", false),
        ("1.2.3.4", false),
        ("localhost", true),
        ("LOCALHOST", true),
        ("denpa", true), // ドットの無い名前
        ("denpa.lan", true),
        ("denpa.local", true),
        ("denpa.home.arpa", true),
        ("denpa.internal", true),
        ("denpa.example.com", false),
        ("::1", true),
        ("fd12::34", true),
        ("fc00::1", true),
        ("fb::1", false),
        ("fe80::1", false), // リンクローカルは入れない (4.2 の表どおり)
        ("2001:db8::1", false),
    ] as [(String, Bool)])
    func indoor(host: String, expected: Bool) {
        #expect(ServerAddress.isIndoor(host) == expected)
    }

    @Test(arguments: [
        // スキームを省いたら家の中なら http://。ポートを省いたら 80 → 3000
        ("denpa.lan", ["http://denpa.lan:80", "http://denpa.lan:3000"]),
        ("192.168.1.20:3000", ["http://192.168.1.20:3000"]),
        ("denpa", ["http://denpa:80", "http://denpa:3000"]),
        ("[::1]", ["http://[::1]:80", "http://[::1]:3000"]),
        // 家の中でなければ https:// で 443 だけ
        ("example.com", ["https://example.com:443"]),
        ("https://example.com", ["https://example.com:443"]),
        ("https://example.com/some/path?x=1", ["https://example.com:443"]), // パス以降は落とす
        ("  HTTPS://Example.com:8443/  ", ["https://Example.com:8443"]),
        ("http://192.168.1.20", ["http://192.168.1.20:80", "http://192.168.1.20:3000"]),
    ] as [(String, [String])])
    func candidates(input: String, expected: [String]) {
        let urls = try! ServerAddress.candidates(input).map(\.url?.absoluteString)
        #expect(urls == expected.map(Optional.some))
    }

    @Test(arguments: [
        ("", ServerAddressError.notURL),
        ("   ", .notURL),
        ("http://", .notURL),
        ("https://", .notURL),
        ("ftp://example.com", .notURL),
        ("http://exa mple.com", .notURL),
        ("http://example.com", .httpsRequired), // 家の中でない http は受けない (D12)
        ("http://1.2.3.4:3000", .httpsRequired),
    ] as [(String, ServerAddressError)])
    func rejects(input: String, expected: ServerAddressError) {
        #expect(throws: expected) { try ServerAddress.candidates(input) }
    }

    @Test func errorMessages() {
        #expect(ServerAddressError.httpsRequired.message == "ローカルネットワーク外からは HTTPS で接続してください")
        #expect(ServerAddressError.notURL.message == "アドレスの形式が正しくありません")
    }
}
