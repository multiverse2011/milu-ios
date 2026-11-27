import Foundation

/// 設定の「バージョン」とライセンスの本文。iPhone/iPad と Apple TV で同じものを使う。
enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    static var license: String {
        guard
            let url = Bundle.main.url(forResource: "OFL", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return String(localized: "ライセンス全文を読み込めませんでした")
        }
        return text
    }
}
