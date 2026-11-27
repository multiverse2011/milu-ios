import Foundation
import Testing

@testable import Milu

struct GenreNameTests {
    @Test func majorNames() {
        #expect(GenreName.major(0) == "ニュース／報道")
        #expect(GenreName.major(7) == "アニメ／特撮")
        #expect(GenreName.major(9) == "劇場／公演")
        #expect(GenreName.major(10) == "趣味／教育")
        #expect(GenreName.major(15) == "その他")
    }

    @Test func majorMisses() {
        // 予備 (0xC・0xD) は放送に出てこないので載せない (arib.ts の表どおり)
        #expect(GenreName.major(12) == nil)
        #expect(GenreName.major(13) == nil)
        #expect(GenreName.major(16) == nil)
    }

    @Test func minorNames() {
        #expect(GenreName.minor(7, 0) == "国内アニメ")
        #expect(GenreName.minor(7, 2) == "特撮")
        #expect(GenreName.minor(3, 2) == "時代劇")
        #expect(GenreName.minor(10, 12) == "教育問題")
        #expect(GenreName.minor(3, 9) == nil)
        #expect(GenreName.minor(12, 0) == nil)
    }

    @Test func labelJoinsWithAngle() {
        #expect(GenreName.label(lv1: 7, lv2: 0) == "アニメ／特撮 › 国内アニメ")
        // 中分類の名前が無ければ大分類だけ
        #expect(GenreName.label(lv1: 3, lv2: 9) == "ドラマ")
        // 大分類が無ければ nil (番組の詳細の事実の行からジャンルを省く)
        #expect(GenreName.label(lv1: 12, lv2: 0) == nil)
    }

    @Test func firstDetailOnly() {
        // genre_detail が複数あれば先頭だけ (3.5.3)
        #expect(GenreName.label(details: [(lv1: 7, lv2: 0), (lv1: 1, lv2: 1)]) == "アニメ／特撮 › 国内アニメ")
        #expect(GenreName.label(details: []) == nil)
    }

    @Test func englishNames() {
        let en = Locale(identifier: "en_US")
        #expect(GenreName.major(0, locale: en) == "News & Reporting")
        #expect(GenreName.major(2, locale: en) == "News & Talk")
        #expect(GenreName.major(7, locale: en) == "Anime & Special Effects")
        #expect(GenreName.major(9, locale: en) == "Theater & Stage")
        #expect(GenreName.major(10, locale: en) == "Hobbies & Education")
        #expect(GenreName.major(15, locale: en) == "Other")

        #expect(GenreName.minor(1, 4, locale: en) == "Other Ball Games")
        #expect(GenreName.minor(1, 6, locale: en) == "Olympics & International Events")
        #expect(GenreName.minor(1, 10, locale: en) == "Horse Racing & Public Sports")
        #expect(GenreName.minor(3, 2, locale: en) == "Period Drama")
        #expect(GenreName.minor(4, 4, locale: en) == "Japanese Pop & Enka")
        #expect(GenreName.minor(5, 2, locale: en) == "Talk Shows")
        #expect(GenreName.minor(5, 5, locale: en) == "Travel Shows")
        #expect(GenreName.minor(5, 6, locale: en) == "Cooking Shows")
        #expect(GenreName.minor(6, 0, locale: en) == "Foreign Films")
        #expect(GenreName.minor(6, 2, locale: en) == "Anime")
        #expect(GenreName.minor(7, 0, locale: en) == "Japanese Anime")
        #expect(GenreName.minor(11, 5, locale: en) == "Captions")

        #expect(GenreName.label(lv1: 7, lv2: 0, locale: en) == "Anime & Special Effects › Japanese Anime")
        #expect(GenreName.label(lv1: 3, lv2: 9, locale: en) == "Drama")
        #expect(GenreName.label(details: [(lv1: 1, lv2: 2)], locale: en) == "Sports › Soccer")
    }
}
