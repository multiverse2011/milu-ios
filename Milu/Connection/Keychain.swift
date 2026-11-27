import Foundation
import Security
import os

/// 接続先の URL ごとのアクセストークン。テストでは差し替える
nonisolated protocol TokenStore: Sendable {
    func load(for url: URL) -> String?
    func save(_ token: String, for url: URL)
    func delete(for url: URL)
}

/// 接続先の URL ごとのアクセストークン (4.2)。前の版の `com.ayushio.milu.session` とは別の入れ物。
nonisolated struct Keychain: TokenStore, Sendable {
    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "app")
    let service: String

    init(service: String = "com.ayushio.milu.denpa") {
        self.service = service
    }

    func load(for url: URL) -> String? {
        var item: CFTypeRef?
        var query = baseQuery(for: url)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            // 読み出せなかったときに黙って「未ペアリング」に戻らないよう、理由を残す
            if status != errSecItemNotFound {
                Self.logger.error("Keychain からの読み出しに失敗: \(status, privacy: .public)")
            }
            return nil
        }
        guard let data = item as? Data else {
            Self.logger.error("Keychain から読み出した値が Data ではない")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String, for url: URL) {
        delete(for: url)
        var query = baseQuery(for: url)
        query[kSecValueData] = Data(token.utf8)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Self.logger.error("Keychain への保存に失敗: \(status, privacy: .public)")
        }
    }

    func delete(for url: URL) {
        let status = SecItemDelete(baseQuery(for: url) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Keychain からの削除に失敗: \(status, privacy: .public)")
        }
    }

    private func baseQuery(for url: URL) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: url.absoluteString,
        ]
    }
}
