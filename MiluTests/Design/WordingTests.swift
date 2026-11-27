import Foundation
import Testing

@testable import Milu

struct WordingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-11-14 (土) 15:00 JST
    private let reference = Date(timeIntervalSince1970: 1_794_636_000)

    private func date(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        (15, 0, "15:00"),
        (9, 5, "9:05"),
        (0, 30, "0:30"),
        (23, 59, "23:59"),
    ] as [(Int, Int, String)])
    func time(hour: Int, minute: Int, expected: String) {
        #expect(Wording.time(date(month: 11, day: 14, hour: hour, minute: minute), calendar: calendar) == expected)
    }

    @Test(arguments: [
        (1_800_000, "30分"),
        (3_600_000, "1時間"),
        (3_660_000, "1時間1分"),
        (6_780_000, "1時間53分"),
        (60_000, "1分"),
        (0, "0分"),
        // 分未満は四捨五入
        (1_799_999, "30分"),
        (59_999, "1分"),
    ] as [(Int64, String)])
    func duration(ms: Int64, expected: String) {
        #expect(Wording.duration(ms) == expected)
    }

    @Test(arguments: [
        (2_340_000, Wording.RemainingKind.ago, "あと39分"),
        (5_280_000, Wording.RemainingKind.left, "残り1時間28分"),
        // 分に切り上げる
        (2_300_000, .ago, "あと39分"),
        (60_001, .ago, "あと2分"),
        (0, .left, "残り0分"),
    ] as [(Int64, Wording.RemainingKind, String)])
    func remaining(ms: Int64, kind: Wording.RemainingKind, expected: String) {
        #expect(Wording.remaining(ms, kind: kind) == expected)
    }

    @Test(arguments: [
        (1_152_000, "19:12"),
        (3_661_000, "1:01:01"),
        (5_000, "0:05"),
        (0, "0:00"),
        (3_599_999, "59:59"),
        (3_600_000, "1:00:00"),
    ] as [(Int64, String)])
    func position(ms: Int64, expected: String) {
        #expect(Wording.position(ms) == expected)
    }

    @Test func dateShort() {
        #expect(Wording.dateShort(date(month: 11, day: 14, hour: 0, minute: 0), calendar: calendar) == "11/14 (土)")
        #expect(Wording.dateShort(date(month: 1, day: 5, hour: 0, minute: 0), calendar: calendar) == "1/5 (月)")
    }

    @Test func timeRangeSeparators() {
        let start = date(month: 11, day: 14, hour: 15, minute: 0)
        let end = date(month: 11, day: 14, hour: 15, minute: 30)
        // ライブのタブと番組の詳細 (U+2013)
        #expect(Wording.timeRange(from: start, to: end, calendar: calendar, separator: .live) == "15:00\u{2013}15:30")
        // 録画・追っかけ・全画面の再生 (U+301C)
        #expect(Wording.timeRange(from: start, to: end, calendar: calendar, separator: .recording) == "15:00\u{301c}15:30")
    }

    private func entry(startAt: Date, endAt: Date, service: String, recording: Bool = false, durationMs: Int64?, resumeMs: Int64?) -> Wording.RecordingListEntry {
        Wording.RecordingListEntry(startAt: startAt, endAt: endAt, serviceName: service, recording: recording, durationMs: durationMs, resumeMs: resumeMs)
    }

    @Test func listRowSubtitles() {
        // 未視聴: 「H:mm · 長さ · 局」
        let unseen = entry(
            startAt: date(month: 11, day: 14, hour: 14, minute: 0),
            endAt: date(month: 11, day: 14, hour: 14, minute: 30),
            service: "あおばTV",
            durationMs: 1_800_000,
            resumeMs: nil
        )
        #expect(Wording.listRowSubtitles(unseen, now: reference, calendar: calendar) == ("14:00 · 30分 · あおばTV", nil))

        // 途中まで観た: 「H:mm · 局 · 残りn分」
        let partial = entry(
            startAt: date(month: 11, day: 14, hour: 13, minute: 0),
            endAt: date(month: 11, day: 14, hour: 13, minute: 30),
            service: "ほしぞら放送",
            durationMs: 1_800_000,
            resumeMs: 1_140_000
        )
        #expect(Wording.listRowSubtitles(partial, now: reference, calendar: calendar) == ("13:00 · ほしぞら放送 · 残り11分", nil))

        // 録画中: 2 段目は「H:mm · 局」、3 段目は「● 録画中 · あとn分」
        let recording = entry(
            startAt: date(month: 11, day: 14, hour: 15, minute: 0),
            endAt: date(month: 11, day: 14, hour: 15, minute: 39),
            service: "ほしぞら放送",
            recording: true,
            durationMs: nil,
            resumeMs: nil
        )
        #expect(Wording.listRowSubtitles(recording, now: reference, calendar: calendar) == ("15:00 · ほしぞら放送", "● 録画中 · あと39分"))
    }

    @Test func cardSubtitle() {
        let unseen = entry(
            startAt: date(month: 11, day: 14, hour: 14, minute: 0),
            endAt: date(month: 11, day: 14, hour: 14, minute: 30),
            service: "あおばTV",
            durationMs: 1_800_000,
            resumeMs: nil
        )
        #expect(Wording.cardSubtitle(unseen, now: reference, calendar: calendar) == "14:00 · 30分 · あおばTV")

        // 途中まで観たものは末尾に「 · 残りn分」
        let partial = entry(
            startAt: date(month: 11, day: 14, hour: 13, minute: 0),
            endAt: date(month: 11, day: 14, hour: 13, minute: 30),
            service: "ほしぞら放送",
            durationMs: 1_800_000,
            resumeMs: 1_140_000
        )
        #expect(Wording.cardSubtitle(partial, now: reference, calendar: calendar) == "13:00 · 30分 · ほしぞら放送 · 残り11分")

        // 1 時間を超える残り
        let longPartial = entry(
            startAt: date(month: 11, day: 14, hour: 13, minute: 0),
            endAt: date(month: 11, day: 14, hour: 14, minute: 53),
            service: "BSみなと",
            durationMs: 6_780_000,
            resumeMs: 1_500_000
        )
        #expect(Wording.cardSubtitle(longPartial, now: reference, calendar: calendar) == "13:00 · 1時間53分 · BSみなと · 残り1時間28分")

        // 録画中は「H:mm · 局 · あとn分」で 1 段
        let recording = entry(
            startAt: date(month: 11, day: 14, hour: 15, minute: 0),
            endAt: date(month: 11, day: 14, hour: 15, minute: 39),
            service: "ほしぞら放送",
            recording: true,
            durationMs: nil,
            resumeMs: nil
        )
        #expect(Wording.cardSubtitle(recording, now: reference, calendar: calendar) == "15:00 · ほしぞら放送 · あと39分")
    }

    @Test func sectionsGroupByDayNewestFirst() {
        let entries = [
            entry(startAt: date(month: 11, day: 14, hour: 13, minute: 0), endAt: date(month: 11, day: 14, hour: 13, minute: 30), service: "A", durationMs: 1_800_000, resumeMs: nil),
            entry(startAt: date(month: 11, day: 14, hour: 8, minute: 0), endAt: date(month: 11, day: 14, hour: 8, minute: 30), service: "B", durationMs: 1_800_000, resumeMs: nil),
            entry(startAt: date(month: 11, day: 13, hour: 20, minute: 0), endAt: date(month: 11, day: 13, hour: 20, minute: 30), service: "C", durationMs: 1_800_000, resumeMs: nil),
        ]
        let sections: [Wording.DateSection<Wording.RecordingListEntry>] = Wording.sections(of: entries, startAt: \.startAt, reference: reference, calendar: calendar)
        #expect(sections.count == 2)
        #expect(sections[0].entries.map(\.serviceName) == ["A", "B"])
        #expect(sections[1].entries.map(\.serviceName) == ["C"])
        let p0 = Wording.dateHeadingParts(sections[0].date, reference: reference, calendar: calendar)
        #expect((p0.primary, p0.secondary) == ("今日", "11月14日 (土)"))
        let p1 = Wording.dateHeadingParts(sections[1].date, reference: reference, calendar: calendar)
        #expect((p1.primary, p1.secondary) == ("昨日", "11月13日 (金)"))
    }

    // MARK: - 英語 (en_US)

    private let en = Locale(identifier: "en_US")
    private let ja = Locale(identifier: "ja_JP")

    @Test(arguments: [
        (1_800_000, "30m"),
        (3_600_000, "1h"),
        (3_660_000, "1h 1m"),
        (6_780_000, "1h 53m"),
        (60_000, "1m"),
        (0, "0m"),
    ] as [(Int64, String)])
    func durationEnglish(ms: Int64, expected: String) {
        #expect(Wording.duration(ms, locale: en) == expected)
    }

    @Test(arguments: [
        (2_340_000, Wording.RemainingKind.ago, "39m left"),
        (5_280_000, Wording.RemainingKind.left, "1h 28m left"),
        (60_001, .ago, "2m left"),
        (0, .left, "0m left"),
    ] as [(Int64, Wording.RemainingKind, String)])
    func remainingEnglish(ms: Int64, kind: Wording.RemainingKind, expected: String) {
        #expect(Wording.remaining(ms, kind: kind, locale: en) == expected)
    }

    // Date.FormatStyle の出力は OS / ICU の更新で変わりうるため、OS の更新で落ちたら書式の変更として見る
    @Test func datesAndWeekdaysEnglish() {
        #expect(Wording.weekday(of: date(month: 11, day: 15, hour: 0, minute: 0), calendar: calendar, locale: en) == "Sun")
        #expect(Wording.weekday(of: date(month: 11, day: 14, hour: 0, minute: 0), calendar: calendar, locale: en) == "Sat")

        #expect(Wording.dateShort(date(month: 11, day: 14, hour: 0, minute: 0), calendar: calendar, locale: en) == "Sat, 11/14")
        #expect(Wording.dateShort(date(month: 1, day: 5, hour: 0, minute: 0), calendar: calendar, locale: en) == "Mon, 1/5")
    }

    @Test func dateHeadingPartsBothLocales() {
        #expect(Wording.dateHeadingParts(reference, reference: reference, calendar: calendar, locale: ja) == ("今日", "11月14日 (土)"))
        #expect(Wording.dateHeadingParts(date(month: 11, day: 13, hour: 20, minute: 0), reference: reference, calendar: calendar, locale: ja) == ("昨日", "11月13日 (金)"))
        #expect(Wording.dateHeadingParts(date(month: 11, day: 12, hour: 20, minute: 0), reference: reference, calendar: calendar, locale: ja) == ("11月12日", "(木)"))

        #expect(Wording.dateHeadingParts(reference, reference: reference, calendar: calendar, locale: en) == ("Today", "· Sat, Nov 14"))
        #expect(Wording.dateHeadingParts(date(month: 11, day: 13, hour: 20, minute: 0), reference: reference, calendar: calendar, locale: en) == ("Yesterday", "· Fri, Nov 13"))
        #expect(Wording.dateHeadingParts(date(month: 11, day: 12, hour: 20, minute: 0), reference: reference, calendar: calendar, locale: en) == ("Nov 12", "Thu"))
    }

    @Test func timeRangeAndSubtitlesEnglish() {
        let start = date(month: 11, day: 14, hour: 15, minute: 0)
        let end = date(month: 11, day: 14, hour: 15, minute: 30)
        #expect(Wording.timeRange(from: start, to: end, calendar: calendar, separator: .live, locale: en) == "15:00\u{2013}15:30")
        #expect(Wording.timeRange(from: start, to: end, calendar: calendar, separator: .recording, locale: en) == "15:00\u{2013}15:30")

        let unseen = entry(
            startAt: date(month: 11, day: 14, hour: 14, minute: 0),
            endAt: date(month: 11, day: 14, hour: 14, minute: 30),
            service: "あおばTV",
            durationMs: 1_800_000,
            resumeMs: nil
        )
        #expect(Wording.listRowSubtitles(unseen, now: reference, calendar: calendar, locale: en) == ("14:00 · 30m · あおばTV", nil))

        let partial = entry(
            startAt: date(month: 11, day: 14, hour: 13, minute: 0),
            endAt: date(month: 11, day: 14, hour: 13, minute: 30),
            service: "ほしぞら放送",
            durationMs: 1_800_000,
            resumeMs: 1_140_000
        )
        #expect(Wording.listRowSubtitles(partial, now: reference, calendar: calendar, locale: en) == ("13:00 · ほしぞら放送 · 11m left", nil))
        #expect(Wording.cardSubtitle(partial, now: reference, calendar: calendar, locale: en) == "13:00 · 30m · ほしぞら放送 · 11m left")

        let recording = entry(
            startAt: date(month: 11, day: 14, hour: 15, minute: 0),
            endAt: date(month: 11, day: 14, hour: 15, minute: 39),
            service: "ほしぞら放送",
            recording: true,
            durationMs: nil,
            resumeMs: nil
        )
        #expect(Wording.listRowSubtitles(recording, now: reference, calendar: calendar, locale: en) == ("15:00 · ほしぞら放送", "● Recording · 39m left"))
        #expect(Wording.cardSubtitle(recording, now: reference, calendar: calendar, locale: en) == "15:00 · ほしぞら放送 · 39m left")
    }
}
