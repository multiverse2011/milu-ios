import Foundation
#if os(tvOS)
import SwiftUI
import UIKit
#endif
import Testing

@testable import Milu

/// GuideText (番組表の画面の字句) の単体テスト。
@Suite struct GuideTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func typeLabels() {
        #expect(GuideText.typeLabel(.GR) == "地上波")
        #expect(GuideText.typeLabel(.BS) == "BS")
        #expect(GuideText.typeLabel(.CS) == "CS")
        #expect(GuideText.typeLabel(.CATV) == "ケーブル")
        #expect(GuideText.typeLabel(.SKY) == "スカパー")
    }

    @Test func sheetHeaderUsesToday() {
        let now = date(14, 15)
        let header = GuideText.sheetHeader(
            serviceName: "BSみなと",
            startAt: date(14, 16),
            endAt: date(14, 17),
            now: now,
            calendar: calendar
        )
        // ライブのタブと番組の詳細は「–」(3.5.3)
        #expect(header == "BSみなと · 今日 16:00\u{2013}17:00")
    }

    @Test func sheetHeaderUsesDateForOtherDays() {
        let now = date(14, 15)
        let header = GuideText.sheetHeader(
            serviceName: "BSみなと",
            startAt: date(15, 0, 30),
            endAt: date(15, 1),
            now: now,
            calendar: calendar
        )
        #expect(header == "BSみなと · 11/15 (日) 0:30\u{2013}1:00")
    }

    @Test func cellBadgesFollowReservationState() {
        #expect(GuideText.cellBadges(reservation: nil).isEmpty)
        let scheduled = ReservationInfo(stateRaw: "scheduled", reason: nil, ruleId: nil)
        #expect(GuideText.cellBadges(reservation: scheduled) == [.reserved])
        let recording = ReservationInfo(stateRaw: "recording", reason: nil, ruleId: nil)
        #expect(GuideText.cellBadges(reservation: recording) == [.recording])
        let conflict = ReservationInfo(stateRaw: "conflict", reason: "理由", ruleId: nil)
        #expect(GuideText.cellBadges(reservation: conflict) == [.conflict])
        // 終わった系はマスに印を出さない
        for raw in ["skipped", "failed", "missed", "done"] {
            let info = ReservationInfo(stateRaw: raw, reason: nil, ruleId: nil)
            #expect(GuideText.cellBadges(reservation: info).isEmpty)
        }
        // 知らない state は落ちない
        let unknown = ReservationInfo(stateRaw: "brand_new", reason: nil, ruleId: nil)
        #expect(GuideText.cellBadges(reservation: unknown).isEmpty)
    }

    @Test func cellLinesFitInsideTheCell() {
        // 30 分のマス (69pt)。題は 2 行で、説明は 1 行
        #expect(GuideText.cellLines(height: 69, hasBadge: false) == GuideCellLines(title: 2, showsBadge: false, description: 1))
        // 予約の印があると、題 1 行・印・説明 1 行
        #expect(GuideText.cellLines(height: 69, hasBadge: true) == GuideCellLines(title: 1, showsBadge: true, description: 1))
        // 44 分のマス (101pt)。題 2 行 + 説明 3 行
        #expect(GuideText.cellLines(height: 101, hasBadge: false) == GuideCellLines(title: 2, showsBadge: false, description: 3))
        // 1 行も入らないマスは何も出さない (行の途中で切らない)
        #expect(GuideText.cellLines(height: 10, hasBadge: false) == GuideCellLines(title: 0, showsBadge: false, description: 0))
        #expect(GuideText.cellLines(height: 29, hasBadge: false).title == 0)
    }

    @Test func cellLinesNeverOverflow() {
        // どの高さでも、出る行がマスの内側に収まる (行の途中で切れない)
        let titleLine = 18.0, detailLine = 15.5, spacing = 2.0
        for height in stride(from: 1.0, through: 400.0, by: 0.5) {
            for hasBadge in [false, true] {
                let lines = GuideText.cellLines(height: height, hasBadge: hasBadge)
                #expect(lines.title >= 0 && lines.description >= 0)
                var used = Double(lines.title) * titleLine
                if lines.showsBadge { used += spacing + detailLine }
                if lines.description > 0 { used += spacing + Double(lines.description) * detailLine }
                if lines.title > 0 {
                    #expect(used <= height - 12)
                }
            }
        }
    }

    #if os(tvOS)
    @Test func tvCellLinesFitInsideTheCell() {
        // 間隔 4pt を引いた 30 分 (134pt) と 1 時間 (272pt) のマスを検証する。
        for (minutes, descriptionLines) in [(30.0, 1), (60.0, 6)] {
            let height = minutes * GuideLayout.tvPointsPerMinute - GuideLayout.tvColumnGap
            let lines = GuideText.tvCellLines(height: height)
            #expect(lines.title == 2)
            #expect(lines.description == descriptionLines)
        }
        // 15 分のマス (69pt) は題 1 行だけ
        #expect(GuideText.tvCellLines(height: 69).title == 1)
        #expect(GuideText.tvCellLines(height: 69).description == 0)
        // 1 行も入らないマスは何も出さない
        #expect(GuideText.tvCellLines(height: 20).title == 0)

        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        for height in stride(from: 1.0, through: 600.0, by: 0.5) {
            let lines = GuideText.tvCellLines(height: height)
            if lines.title > 0 {
                #expect(realHeight(lines, traits: traits) <= height - 20)
            }
        }
    }

    /// 文字の大きさの設定を上げても、見積りは実フォントの行の高さに追従してはみ出さない
    @Test func tvCellLinesFollowTheTextSize() {
        let height = 60 * GuideLayout.tvPointsPerMinute - GuideLayout.tvColumnGap
        let standard = GuideText.tvCellLines(height: height, dynamicTypeSize: .large)
        let enlarged = GuideText.tvCellLines(height: height, dynamicTypeSize: .accessibility1)
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        #expect(enlarged.title > 0)
        #expect(enlarged.title + enlarged.description < standard.title + standard.description)
        #expect(realHeight(enlarged, traits: traits) <= height - 20)
    }

    /// 実フォント (Denpa Font) の行の高さで並べたときの高さ。実装の見積りとは別に UIFont から測る
    private func realHeight(_ lines: (title: Int, description: Int), traits: UITraitCollection) -> Double {
        var used = Double(lines.title) * Double(denpaLineHeight(system: .callout, traits: traits))
        if lines.description > 0 {
            used += 4 + Double(lines.description) * Double(denpaLineHeight(system: .caption1, traits: traits))
        }
        return used
    }

    private func denpaLineHeight(system style: UIFont.TextStyle, traits: UITraitCollection) -> CGFloat {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        return UIFont(name: DenpaFont.postScriptName, size: size)?.lineHeight ?? size
    }
    #endif

    @Test func extendedItemsPutPreferredFirstThenSorted() {
        let extended = ["出演者": "A", "その他": "X", "番組内容": "B", "解説": "Y"]
        let items = GuideText.extendedItems(extended)
        #expect(items.map(\.heading) == ["番組内容", "出演者", "その他", "解説"])
        #expect(items[0].body == "B")
    }

    @Test func extendedItemsSkipsMissingPreferred() {
        let items = GuideText.extendedItems(["番組内容": "B"])
        #expect(items.map(\.heading) == ["番組内容"])
    }

    @Test func englishLabelsAndHeaders() {
        let en = Locale(identifier: "en_US")
        #expect(GuideText.typeLabel(.GR, locale: en) == "Terrestrial")
        #expect(GuideText.typeLabel(.BS, locale: en) == "BS")
        #expect(GuideText.typeLabel(.CS, locale: en) == "CS")
        #expect(GuideText.typeLabel(.CATV, locale: en) == "Cable")
        #expect(GuideText.typeLabel(.SKY, locale: en) == "SKY")

        let now = date(14, 15)
        let todayHeader = GuideText.sheetHeader(
            serviceName: "BSみなと",
            startAt: date(14, 16),
            endAt: date(14, 17),
            now: now,
            calendar: calendar,
            locale: en
        )
        #expect(todayHeader == "BSみなと · Today 16:00\u{2013}17:00")

        let otherHeader = GuideText.sheetHeader(
            serviceName: "BSみなと",
            startAt: date(15, 0, 30),
            endAt: date(15, 1),
            now: now,
            calendar: calendar,
            locale: en
        )
        #expect(otherHeader == "BSみなと · Sun, 11/15 0:30\u{2013}1:00")

        #expect(GuideCellBadge.reserved.text(locale: en) == "Scheduled")
        #expect(GuideCellBadge.recording.text(locale: en) == "● Recording")
        #expect(GuideCellBadge.conflict.text(locale: en) == "⚠︎ Conflict")
    }

    @Test func extendedHeadingTranslatesKnownKeysInEnglish() {
        let en = Locale(identifier: "en_US")
        let ja = Locale(identifier: "ja_JP")
        #expect(GuideText.extendedHeading("番組内容", locale: en) == "Description")
        #expect(GuideText.extendedHeading("出演者", locale: en) == "Cast")
        #expect(GuideText.extendedHeading("解説", locale: en) == "解説")
        #expect(GuideText.extendedHeading("その他", locale: en) == "その他")

        #expect(GuideText.extendedHeading("番組内容", locale: ja) == "番組内容")
        #expect(GuideText.extendedHeading("出演者", locale: ja) == "出演者")
        #expect(GuideText.extendedHeading("解説", locale: ja) == "解説")
    }
}
