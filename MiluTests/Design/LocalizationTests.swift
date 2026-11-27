import Foundation
import Testing

@testable import Milu

struct LocalizationTests {
    private let ja = Locale(identifier: "ja_JP")
    private let en = Locale(identifier: "en_US")

    @Test func bundleSupportsJapaneseAndEnglish() throws {
        let localizations = Set(Bundle.main.localizations)
        #expect(localizations.contains("ja"))
        #expect(localizations.contains("en"))

        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let enBundle = try #require(Bundle(path: enPath))
        #expect(
            enBundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist")
                == "Used to connect to denpa on your local network."
        )
    }

    @Test func deviceNames() {
        #expect(DeviceName.name(isPad: false, locale: ja) == "iPhone")
        #expect(DeviceName.name(isPad: true, locale: ja) == "iPad")
        #expect(DeviceName.name(isPad: false, locale: en) == "iPhone")
        #expect(DeviceName.name(isPad: true, locale: en) == "iPad")
        #expect(DeviceName.name(isPad: false, isTV: true, locale: ja) == "Apple TV")
        #expect(DeviceName.name(isPad: false, isTV: true, locale: en) == "Apple TV")
    }

    @Test func homographsResolvePerContext() throws {
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let enBundle = try #require(Bundle(path: enPath))
        #expect(enBundle.localizedString(forKey: "録画", value: nil, table: nil) == "Recordings")
        #expect(enBundle.localizedString(forKey: "録画 (操作)", value: nil, table: nil) == "Record")
        #expect(enBundle.localizedString(forKey: "再生", value: nil, table: nil) == "Play")
        #expect(enBundle.localizedString(forKey: "再生 (設定)", value: nil, table: nil) == "Playback")
        #expect(enBundle.localizedString(forKey: "その他", value: nil, table: nil) == "Other")
        #expect(enBundle.localizedString(forKey: "その他 (メニュー)", value: nil, table: nil) == "More")
    }

    @Test func allEnglishTranslationsAreTranslatedAndNonEmpty() throws {
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let stringsPath = (enPath as NSString).appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: URL(fileURLWithPath: stringsPath))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: String])

        for (key, value) in dict {
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty translation for key: \(key)")
        }
        #expect(dict["番組内容 (見出し)"] == "Description")
        #expect(dict["出演者 (見出し)"] == "Cast")

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Milu")
            .appendingPathComponent("Localizable.xcstrings")
        try #require(FileManager.default.fileExists(atPath: sourceURL.path), "Localizable.xcstrings not found at \(sourceURL.path)")

        let catalogData = try Data(contentsOf: sourceURL)
        let jsonObject = try JSONSerialization.jsonObject(with: catalogData)
        let root = try #require(jsonObject as? [String: Any])
        let catalogStrings = try #require(root["strings"] as? [String: Any])

        #expect(!catalogStrings.isEmpty)
        #expect(dict.count == catalogStrings.count)

        func extractStringUnits(from node: Any) -> [(state: String, value: String)] {
            var units: [(state: String, value: String)] = []
            if let dict = node as? [String: Any] {
                if let state = dict["state"] as? String, let value = dict["value"] as? String {
                    units.append((state: state, value: value))
                } else {
                    for (_, child) in dict {
                        units.append(contentsOf: extractStringUnits(from: child))
                    }
                }
            }
            return units
        }

        for (key, entryAny) in catalogStrings {
            let entry = try #require(entryAny as? [String: Any], "Invalid entry format for key: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "Missing localizations for key: \(key)")
            let en = try #require(localizations["en"], "Missing en localization for key: \(key)")
            let units = extractStringUnits(from: en)
            #expect(!units.isEmpty, "No string units found in en localization for key: \(key)")
            for unit in units {
                #expect(unit.state == "translated", "State is not translated for key: \(key) (was \(unit.state))")
                #expect(!unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty en value for key: \(key)")
            }
        }
    }

    /// Apple TV の画面の文言が抜けていないこと (en の訳も)。TV の文言を足したらこの一覧にも足す
    @Test func tvStringsAreLocalized() throws {
        // キーが無いときに localizedString はキーをそのまま返す。キーと同じ訳 (Apple TV) と見分けるため .strings を直に見る
        let enPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let stringsPath = (enPath as NSString).appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: URL(fileURLWithPath: stringsPath))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let translations = try #require(plist as? [String: String])
        let keys = [
            "denpa に繋ぐ",
            "繋ぐ",
            "家の denpa の Web 画面を開くときのアドレスを入れてください。\niPhone のキーボードからも打てます。",
            "denpa が見つかりません。アドレスを確認してください。",
            "この Apple TV を許可する",
            "%@ はログインが要ります。\nスマホで QR を読み取り、denpa にログインして、\n出てきた画面でコードが同じことを確かめて許可してください。",
            "許可を待っています",
            "接続先を変える",
            "押すと接続先を変えます",
            "番組名・局名・字幕の字に使っています。SIL Open Font License 1.1 で配られています。",
            "▼ 下キーで続き",
            "アドレスを変更して「再接続」を押すと、接続先を切り替えられます。",
            "状態: %@",
            // ライブ (TV-Live・TV-LiveHud・TV-LiveTuning・TV-LiveDetail)
            "Apple TV",
            "選局しています",
            "視聴中",
            "いま選んでいる局",
            "● 録画",
            // PR 4 (番組表と予約)
            "番組表",
            "明日",
            "%lld (%@)",
            "予約",
            "予約取消",
            // PR 2 (録画・再生。TV-Recordings・TV-RecordingDetail・TV-Player・TV-Chase・TV-PlayerEnd)
            "長押しでメニューから詳細",
            "まだ観ていない",
            "録画はまだありません",
            "番組表で番組を予約すると、録れたものがここに並びます。",
            "ライブへ",
            "Wi-Fi などの接続状況を確認してください。",
            "続きから再生 (%@)",
            "次のチャプター",
            "自動 (%@)",
            "%@ まで録れています",
            "この Apple TV に対応した映像形式がありません。",
            "最後まで観ました",
            "一覧へ戻る",
            // 札の題
            "一時停止",
            "再生",
            "最新",
            "速度",
            "CM 飛ばし",
            "再試行",
            "閉じる",
            "削除",
            "最初から",
            "音声",
            "自動",
            "● 録画中",
            // 止まった画面の題と理由
            "再生できる形式がありません",
            "この録画は再生できません",
            "サーバーが混み合っています",
            "映像を受信できませんでした",
            "再生できません",
            "映像のない録画は再生できません。",
        ]
        for key in keys {
            let value = translations[key]
            #expect(value != nil, "Missing en translation for TV string: \(key)")
            #expect(!(value ?? "").isEmpty, "Empty en translation for TV string: \(key)")
        }
    }
}
