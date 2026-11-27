import Foundation
import Testing
@testable import Milu

/// 実物の Keychain を使う。署名なし (CODE_SIGNING_ALLOWED=NO) のビルドでは entitlement が無くて落ちる
@Suite struct KeychainTests {
    private let url = URL(string: "http://127.0.0.1:3000")!

    @Test func savesLoadsAndDeletes() {
        let keychain = Keychain(service: "KeychainTests-\(UUID().uuidString)")
        defer { keychain.delete(for: url) }
        keychain.save("token", for: url)
        #expect(keychain.load(for: url) == "token")
        keychain.delete(for: url)
        #expect(keychain.load(for: url) == nil)
    }
}
