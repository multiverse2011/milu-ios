import Foundation
import Security
import os

/// 前の版 (別のサーバ向けの Milu) が端末に残したものを、初回だけ消す (D14)。
/// 新しい版も `serverURL` を使うので、接続先を読むより前に走らせる。
nonisolated enum Migration {
    private static let doneKey = "denpaMigrationDone"
    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "app")

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        defaults.removeObject(forKey: "serverURL")
        defaults.removeObject(forKey: "guideZoomed")
        defaults.removeObject(forKey: "landscapePlayback")

        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.ayushio.milu.session",
        ] as CFDictionary)

        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let downloads = support.appending(path: "Downloads", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: downloads)
        }
        URLCache.shared.removeAllCachedResponses()

        // 前の版の背景のダウンロード (同じ識別子) の残りのタスクを取り消す。
        // 前の版は tvOS に無いので消すものが無い (D14)。背景の URLSession も tvOS に無い
        #if os(iOS)
        let session = URLSession(configuration: .background(withIdentifier: "com.ayushio.milu.downloads"))
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
            session.invalidateAndCancel()
        }
        #endif

        defaults.set(true, forKey: doneKey)
        logger.info("前の版の残りを消しました")
    }
}
