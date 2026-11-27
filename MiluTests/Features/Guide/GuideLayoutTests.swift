import Foundation
import Testing

@testable import Milu

/// 番組表の格子の置き方の単体テスト (8 節)。
struct GuideLayoutTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        date(day, hour, minute).timeIntervalSince1970 * 1000
    }

    @Test func pointsPerMinute() {
        // 1 分 2.3pt
        let rangeStart = ms(14, 4)
        #expect(GuideLayout.offset(of: ms(14, 15), from: rangeStart) == 660 * 2.3)
        #expect(GuideLayout.height(rangeStart: rangeStart, rangeEnd: ms(15, 4)) == 1440 * 2.3)
    }

    @Test func cellFrame() {
        let rangeStart = ms(14, 4)
        let rangeEnd = ms(15, 4)
        // 15:00〜15:30
        let frame = GuideLayout.frame(start: ms(14, 15), end: ms(14, 15, 30), rangeStart: rangeStart, rangeEnd: rangeEnd)
        #expect(frame?.top == 660 * 2.3)
        #expect(frame?.height == 30 * 2.3)
        // 表の前に始まる番組は切る
        let crossing = GuideLayout.frame(start: ms(14, 3, 30), end: ms(14, 4, 30), rangeStart: rangeStart, rangeEnd: rangeEnd)
        #expect(crossing?.top == 0)
        #expect(crossing?.height == 30 * 2.3)
        // 表をまたぐ番組は後ろも切る
        let tail = GuideLayout.frame(start: ms(15, 3, 45), end: ms(15, 4, 30), rangeStart: rangeStart, rangeEnd: rangeEnd)
        #expect(tail?.top == 1425 * 2.3)
        #expect(tail?.height == 15 * 2.3)
        // 範囲に重ならなければ nil
        #expect(GuideLayout.frame(start: ms(15, 5), end: ms(15, 6), rangeStart: rangeStart, rangeEnd: rangeEnd) == nil)
    }

    @Test func nowLine() {
        let rangeStart = ms(14, 4)
        let rangeEnd = ms(15, 4)
        // いまの線。範囲の外なら nil
        #expect(GuideLayout.nowOffset(now: ms(14, 15, 30), rangeStart: rangeStart, rangeEnd: rangeEnd) == 690 * 2.3)
        #expect(GuideLayout.nowOffset(now: ms(15, 4), rangeStart: rangeStart, rangeEnd: rangeEnd) == nil)
        // 開いたときはいまの線が上から 1/4 に来る所へ送る
        #expect(GuideLayout.initialScrollOffset(nowOffset: 1000, viewportHeight: 800) == 800)
        #expect(GuideLayout.initialScrollOffset(nowOffset: 100, viewportHeight: 800) == 0)
        // いまの線の数字。iPhone が分だけ、iPad が H:mm
        let now = date(14, 15, 21)
        #expect(GuideLayout.nowLineLabel(now: now, horizontalSizeClassRegular: false) == "21")
        #expect(GuideLayout.nowLineLabel(now: now, horizontalSizeClassRegular: true) == "15:21")
    }

    @Test func tvFollowShowsBothLinesAtTheBottom() {
        let offset = GuideLayout.tvFollowOffset(
            scrollY: 0, viewportHeight: 700, anchorY: 680, cell: 682...1230, headingHeight: 88
        )
        #expect(offset == 70)
    }

    @Test func tvCellHeadingTracksTheViewportAndStaysInsideTheCell() {
        #expect(GuideLayout.tvCellContentInset(viewportTop: -20, viewportHeight: 700, cellHeight: 1600, headingHeight: 88) == 0)
        #expect(GuideLayout.tvCellContentInset(viewportTop: 1100, viewportHeight: 700, cellHeight: 1600, headingHeight: 88) == 1100)
        #expect(GuideLayout.tvCellContentInset(viewportTop: 1512, viewportHeight: 700, cellHeight: 1600, headingHeight: 88) == 1512)
    }

    @Test func tvCellHeadingIsHiddenWhenOnlyPartFits() {
        #expect(GuideLayout.tvCellContentInset(viewportTop: 1513, viewportHeight: 700, cellHeight: 1600, headingHeight: 88) == nil)
        #expect(GuideLayout.tvCellContentInset(viewportTop: -680, viewportHeight: 700, cellHeight: 1600, headingHeight: 88) == nil)
        #expect(GuideLayout.tvCellContentInset(viewportTop: 10, viewportHeight: 60, cellHeight: 1600, headingHeight: 88) == nil)
    }

    @Test func tvFollowKeepsTheAnchorInsideALongProgram() {
        let offset = GuideLayout.tvFollowOffset(
            scrollY: 1800, viewportHeight: 700, anchorY: 2000, cell: 500...2160, headingHeight: 88
        )
        #expect(offset == 1800)
    }

    @Test func tvFollowMakesRoomForTheHeadingAtTheTop() {
        let offset = GuideLayout.tvFollowOffset(
            scrollY: 2000, viewportHeight: 700, anchorY: 2070, cell: 500...2080, headingHeight: 88
        )
        #expect(offset == 1992)
    }

    @Test func tvFollowPreservesTheAnchorWhenTheCellIsTooFarAway() {
        let offset = GuideLayout.tvFollowOffset(
            scrollY: 1000, viewportHeight: 700, anchorY: 1950, cell: 100...550, headingHeight: 88
        )
        #expect(offset == 1290)
    }

    @Test func columns() {
        // 列の幅は iPhone 158pt・iPad 186pt、列の間 2pt
        #expect(GuideLayout.columnWidth(horizontalSizeClassRegular: false) == 158)
        #expect(GuideLayout.columnWidth(horizontalSizeClassRegular: true) == 186)
        #expect(GuideLayout.visibleColumns(width: 402, horizontalSizeClassRegular: false) == 2)
        #expect(GuideLayout.visibleColumns(width: 1180, horizontalSizeClassRegular: true) == 6)
        #expect(GuideLayout.visibleColumns(width: 100, horizontalSizeClassRegular: false) == 1)
    }

    @Test func broadcastDay() {
        // 4:00 から翌 4:00 が放送日。4:00 より前は前の日
        #expect(calendar.isDate(GuideLayout.broadcastDay(for: date(14, 3, 59), calendar: calendar), inSameDayAs: date(13, 0)))
        #expect(calendar.isDate(GuideLayout.broadcastDay(for: date(14, 4), calendar: calendar), inSameDayAs: date(14, 0)))
        let range = GuideLayout.broadcastRange(for: date(14, 0), calendar: calendar)
        #expect(range.from == 1_794_596_400_000)
        #expect(range.to == 1_794_682_800_000)
        #expect(range.to - range.from == 86_400_000)
    }

    @Test func dateMenu() {
        let now = date(14, 15)
        // 今日から 8 日ぶん
        let days = GuideLayout.menuDays(now: now, until: nil, calendar: calendar)
        #expect(days.count == 8)
        #expect(calendar.isDate(days[0], inSameDayAs: date(14, 0)))
        #expect(calendar.isDate(days[7], inSameDayAs: date(21, 0)))

        // until より先の日は並べない
        let limited = GuideLayout.menuDays(now: now, until: Int64(ms(16, 4)), calendar: calendar)
        #expect(limited.count == 2)
        #expect(calendar.isDate(limited[1], inSameDayAs: date(15, 0)))

        // 0 時台は前の日の番組表が「今日」
        let early = GuideLayout.menuDays(now: date(14, 2), until: nil, calendar: calendar)
        #expect(calendar.isDate(early[0], inSameDayAs: date(13, 0)))

        #expect(GuideLayout.menuLabel(for: days[0], today: now, calendar: calendar) == "今日 14日 (土)")
        #expect(GuideLayout.menuLabel(for: days[1], today: now, calendar: calendar) == "15日 (日)")
        #expect(GuideLayout.menuLabel(for: days[7], today: now, calendar: calendar) == "21日 (土)")

        // Date.FormatStyle の出力は OS / ICU の更新で変わりうるため、OS の更新で落ちたら書式の変更として見る
        let en = Locale(identifier: "en_US")
        #expect(GuideLayout.menuLabel(for: days[0], today: now, calendar: calendar, locale: en) == "Today, Sat 14")
        #expect(GuideLayout.menuLabel(for: days[1], today: now, calendar: calendar, locale: en) == "Sun 15")
        #expect(GuideLayout.menuLabel(for: days[7], today: now, calendar: calendar, locale: en) == "Sat 21")
    }

    @Test func tvColumnFocusRangesStayInsideTheGrid() {
        let width = 850 - GuideLayout.tvTimeWidth
        let edge = 3 * (GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap)
        #expect(GuideLayout.tvColumnFocusRange(0, scrollX: 0, visibleWidth: width) == 0..<262)
        #expect(GuideLayout.tvColumnFocusRange(3, scrollX: 0, visibleWidth: width) == nil)
        #expect(GuideLayout.tvColumnFocusRange(3, scrollX: edge - width, visibleWidth: width) == nil)
        #expect(GuideLayout.tvColumnFocusRange(3, scrollX: edge - width + 1, visibleWidth: width) == (width - 1)..<width)
        #expect(GuideLayout.tvColumnFocusRange(0, scrollX: 242, visibleWidth: width) == 0..<20)
        #expect(GuideLayout.tvColumnFocusRange(0, scrollX: 280, visibleWidth: width) == nil)
        #expect(GuideLayout.tvColumnFocusRange(0, scrollX: 0, visibleWidth: 0) == nil)
    }

    @Test func tvEdgeTargetIsOnlyNeededForAnOffscreenNeighbor() {
        let width = 850 - GuideLayout.tvTimeWidth
        #expect(GuideLayout.tvNeedsColumnEdgeTarget(neighbor: 3, scrollX: 0, visibleWidth: width))
        #expect(GuideLayout.tvNeedsColumnEdgeTarget(neighbor: 0, scrollX: 280, visibleWidth: width))
        #expect(!GuideLayout.tvNeedsColumnEdgeTarget(neighbor: 3, scrollX: 19, visibleWidth: width))
        #expect(!GuideLayout.tvNeedsColumnEdgeTarget(neighbor: nil, scrollX: 0, visibleWidth: width))
        #expect(!GuideLayout.tvNeedsColumnEdgeTarget(neighbor: 3, scrollX: 0, visibleWidth: 0))
    }

    @Test(arguments: [3, 5])
    func tvHorizontalDestinationCreatesAFullWidthFocusTarget(column: Int) {
        let viewportWidth = 850.0
        let visibleWidth = viewportWidth - GuideLayout.tvTimeWidth
        let x = GuideLayout.tvFollowColumnOffset(
            scrollX: 0, visibleWidth: visibleWidth, column: column, previous: 0, next: nil
        )
        let back = GuideLayout.tvFollowColumnOffset(
            scrollX: x, visibleWidth: visibleWidth, column: 0, previous: nil, next: column
        )
        let step = GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap
        for (destination, before, after) in [(column, 0.0, x), (0, x, back)] {
            #expect(GuideLayout.tvColumnFocusRange(destination, scrollX: before, visibleWidth: visibleWidth) == nil)
            let left = Double(destination) * step - after
            let cell = left..<(left + GuideLayout.tvColumnWidth)
            #expect(GuideLayout.tvColumnFocusRange(destination, scrollX: after, visibleWidth: visibleWidth) == cell)
            #expect(GuideLayout.tvColumnRange(scrollX: after, width: viewportWidth, count: column + 1).contains(destination))
        }
    }

    @Test func tvHorizontalFollowKeepsTheSelectedColumnAcrossAGap() {
        let width = 850 - GuideLayout.tvTimeWidth
        let step = GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap
        let right = GuideLayout.tvFollowColumnOffset(scrollX: 0, visibleWidth: width, column: 5, previous: 0, next: nil)
        #expect(right <= 5 * step)
        #expect(right + width >= 5 * step + GuideLayout.tvColumnWidth)

        let left = GuideLayout.tvFollowColumnOffset(scrollX: right, visibleWidth: width, column: 0, previous: nil, next: 5)
        #expect(left <= 0)
        #expect(left + width >= GuideLayout.tvColumnWidth)
    }

    @Test func tvColumnsStayInsideTheGuide() {
        // 局が減った (読み直しの前後) ときも、番組表の外の列は作らない
        for count in 1...6 {
            for scrollX in stride(from: 0.0, through: 20_000, by: 137) {
                let range = GuideLayout.tvColumnRange(scrollX: scrollX, width: 1100, count: count)
                #expect(!range.isEmpty)
                #expect(range.lowerBound >= 0)
                #expect(range.upperBound <= count)
            }
        }
        #expect(GuideLayout.tvColumnRange(scrollX: 0, width: 1100, count: 0).isEmpty)
        // 見えている列と前後 1 列ぶんを選ぶ
        #expect(GuideLayout.tvColumnRange(scrollX: 0, width: 1100, count: 6) == 0..<6)
        #expect(GuideLayout.tvColumnRange(scrollX: 266 * 3, width: 500, count: 6) == 2..<6)
    }

    @Test func tvHorizontalFollowShowsAServiceThatMovedBeyondTheOldWidth() throws {
        let program = GuideProgram(
            id: 10, name: "番組", startAt: 0, endAt: 1000, description: nil,
            genre: nil, copyNever: false, reservation: nil, recordingId: nil
        )
        let services = [8, 5, 3, 2, 4, 9].map { id in
            GuideService(id: Int64(id), name: "局", mainId: nil, remoteControlKey: nil, logo: nil, programs: [program])
        }
        let selectedService: Int64 = 9
        // 元の 3 局のうち、選択局より右にあった局が左へ移る。
        let previousServices = [services[4], services[5], services[1]]
        let column = try #require(services.firstIndex { $0.id == selectedService })
        #expect(previousServices.firstIndex { $0.id == selectedService } == 1)
        #expect(column == 5)
        let viewportWidth = 850.0
        let visibleWidth = viewportWidth - GuideLayout.tvTimeWidth
        let x = GuideLayout.tvFollowColumnOffset(
            scrollX: 0, visibleWidth: visibleWidth, column: column,
            previous: GuideCursorMotion.adjacentColumn(from: column, in: services, by: -1), next: nil
        )
        let columnLeft = Double(column) * (GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap)
        #expect(x > 0)
        #expect(x <= columnLeft)
        #expect(columnLeft + GuideLayout.tvColumnWidth <= x + viewportWidth - GuideLayout.tvTimeWidth)
    }

    @Test func tvWindowAroundCursor() {
        // チップに出る日は 0 時の日付 (14〜21)。center も放送日そのもの (0:00) を渡す
        let first = date(14, 0)
        let last = date(21, 0)
        #expect(GuideLayout.tvWindowDays(center: date(14, 0), first: first, last: last) == [date(14, 0), date(15, 0)])
        #expect(GuideLayout.tvWindowDays(center: date(15, 0), first: first, last: last) == [date(14, 0), date(15, 0), date(16, 0)])
        #expect(GuideLayout.tvWindowDays(center: date(16, 0), first: first, last: last) == [date(15, 0), date(16, 0), date(17, 0)])
        // 4:00 より前は前の放送日。呼び出し側が broadcastDay で丸める
        #expect(GuideLayout.broadcastDay(for: date(16, 2), calendar: calendar) == date(15, 0))
        // 最後の日はそこで止める
        #expect(GuideLayout.tvWindowDays(center: date(21, 0), first: first, last: last) == [date(20, 0), date(21, 0)])
        // until で最後の日が縮んだとき
        #expect(GuideLayout.tvWindowDays(center: date(16, 0), first: first, last: date(16, 0)) == [date(15, 0), date(16, 0)])
        // 起点の日より前は持たない
        #expect(GuideLayout.tvWindowDays(center: date(15, 0), first: date(15, 0), last: last) == [date(15, 0), date(16, 0)])
    }

    @Test func tvTopEdgeWaitsOnlyIfThereIsAnEarlierDay() {
        let base = date(14, 0)
        #expect(GuideLayout.tvHasPreviousDay(firstLoaded: date(15, 0), base: base))
        #expect(!GuideLayout.tvHasPreviousDay(firstLoaded: base, base: base))
        #expect(!GuideLayout.tvHasPreviousDay(firstLoaded: nil, base: base))
    }

    @Test func tvPrependingADayExtendsTheScrollRangeWithoutMovingTheExistingPositions() {
        let origin = ms(14, 4)
        let end = ms(18, 4)
        let before = GuideLayout.tvScrollRange(origin: origin, loadedStart: ms(16, 4), loadedEnd: end, viewportHeight: 700)
        let after = GuideLayout.tvScrollRange(origin: origin, loadedStart: ms(15, 4), loadedEnd: end, viewportHeight: 700)
        let dayHeight = 1_440 * GuideLayout.tvPointsPerMinute
        #expect(before.lowerBound == 2 * dayHeight)
        #expect(after.lowerBound == dayHeight)
        #expect(after.upperBound == before.upperBound)

        let scrollLow = before.lowerBound
        let scrollHigh = scrollLow + 200
        let ringTop = GuideLayout.offset(of: ms(16, 4, 30), from: origin, pointsPerMinute: GuideLayout.tvPointsPerMinute)
        for range in [before, after] {
            #expect(range.contains(scrollLow))
            #expect(range.contains(scrollHigh))
            let interpolatedScrollY = min(max(range.lowerBound, scrollLow + 60), range.upperBound)
            #expect(ringTop - interpolatedScrollY == 30 * GuideLayout.tvPointsPerMinute - 60)
        }
    }

    @Test func dayHeading() {
        #expect(GuideLayout.dayHeading(for: date(29, 0), calendar: calendar) == "11/29")
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        #expect(GuideLayout.dayHeading(for: december, calendar: calendar) == "12/1")
    }

    @Test func tvDayChips() {
        // TV-Guide の日付のチップは「今日」「明日」「16 (月)」
        let now = date(14, 15)
        #expect(GuideLayout.dayChipLabel(for: date(14, 4), today: now, calendar: calendar) == "今日")
        #expect(GuideLayout.dayChipLabel(for: date(15, 4), today: now, calendar: calendar) == "明日")
        #expect(GuideLayout.dayChipLabel(for: date(16, 4), today: now, calendar: calendar) == "16 (月)")
        // 0 時台は前の放送日が「今日」になり、その翌日が「明日」
        let early = date(14, 2)
        #expect(GuideLayout.dayChipLabel(for: date(13, 4), today: early, calendar: calendar) == "今日")
        #expect(GuideLayout.dayChipLabel(for: date(14, 4), today: early, calendar: calendar) == "明日")

        let en = Locale(identifier: "en_US")
        #expect(GuideLayout.dayChipLabel(for: date(15, 4), today: now, calendar: calendar, locale: en) == "Tomorrow")
        #expect(GuideLayout.dayChipLabel(for: date(16, 4), today: now, calendar: calendar, locale: en) == "16 (Mon)")
    }
}
