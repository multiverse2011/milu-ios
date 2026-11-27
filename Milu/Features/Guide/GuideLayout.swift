import Foundation

/// 番組表の格子の置き方 (3.5「番組表」)。純粋な関数だけを置く。時刻は UNIX ミリ秒。
nonisolated enum GuideLayout {
    /// 1 分の高さ (pt)
    static let pointsPerMinute = 2.3
    /// 列の間 (pt)
    static let columnGap = 2.0

    /// tvOS の寸法 (TV-Guide の画面案。1920×1080 の pt)
    static let tvPointsPerMinute = 4.6
    static let tvColumnWidth = 262.0
    static let tvColumnGap = 4.0
    /// 時刻の列の幅 (字の大きさが既定のとき)。画面は字の大きさに合わせて広げる
    static let tvTimeWidth = 70.0

    /// 放送日の始まりの時刻 (時)。4:00 から翌 4:00 (日本のテレビの日付の決まり)
    static let broadcastDayStartHour = 4

    /// 番組表の時刻は日本の放送にそろえる
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 列の幅。iPhone 158pt・iPad 186pt
    static func columnWidth(horizontalSizeClassRegular: Bool) -> Double {
        horizontalSizeClassRegular ? 186 : 158
    }

    /// 時刻の列の幅。iPhone 28pt・iPad 44pt (画面案の x0)
    static func timeColumnWidth(horizontalSizeClassRegular: Bool) -> Double {
        horizontalSizeClassRegular ? 44 : 28
    }

    /// 幅に入る列の数 (残りは横へ送る)。1 列は出す。
    static func visibleColumns(width: Double, horizontalSizeClassRegular: Bool) -> Int {
        let column = columnWidth(horizontalSizeClassRegular: horizontalSizeClassRegular)
        return max(Int((width + columnGap) / (column + columnGap)), 1)
    }

    /// TV-Guide で作る列の範囲。横の送り位置と見えている幅から選ぶ (前後 1 列ぶんの余白を付ける)
    static func tvColumnRange(scrollX: Double, width: Double, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let step = tvColumnWidth + tvColumnGap
        let margin = step
        // 局が減ると送り位置が古いままになる。範囲の外の列は作らない
        let first = min(max(0, Int(((scrollX - margin) / step).rounded(.down))), count - 1)
        let last = min(count - 1, Int(((scrollX + width + margin) / step).rounded(.down)))
        return first..<(max(first, last) + 1)
    }

    static func offset(
        of time: Double,
        from rangeStart: Double,
        pointsPerMinute ppm: Double = GuideLayout.pointsPerMinute
    ) -> Double {
        (time - rangeStart) / 60_000 * ppm
    }

    /// 表全体の高さ (pt)
    static func height(
        rangeStart: Double,
        rangeEnd: Double,
        pointsPerMinute ppm: Double = GuideLayout.pointsPerMinute
    ) -> Double {
        offset(of: rangeEnd, from: rangeStart, pointsPerMinute: ppm)
    }

    /// マスの上端と高さ (pt)。表の範囲 (`rangeStart`〜`rangeEnd`) の外に出た部分は切る。範囲に重ならなければ `nil`
    static func frame(
        start: Double,
        end: Double,
        rangeStart: Double,
        rangeEnd: Double,
        pointsPerMinute ppm: Double = GuideLayout.pointsPerMinute
    ) -> (top: Double, height: Double)? {
        let top = max(start, rangeStart)
        let bottom = min(end, rangeEnd)
        guard bottom > top else { return nil }
        let y = offset(of: top, from: rangeStart, pointsPerMinute: ppm)
        return (y, offset(of: bottom, from: rangeStart, pointsPerMinute: ppm) - y)
    }

    /// いまの線の位置 (pt)。いまが表の範囲の外なら `nil` (今日の表だけ出す)
    static func nowOffset(
        now: Double,
        rangeStart: Double,
        rangeEnd: Double,
        pointsPerMinute ppm: Double = GuideLayout.pointsPerMinute
    ) -> Double? {
        guard rangeStart <= now, now < rangeEnd else { return nil }
        return offset(of: now, from: rangeStart, pointsPerMinute: ppm)
    }

    /// 開いたときに送る位置 (pt)。いまの線が上から 1/4 に来る所。負にならないようにする。
    static func initialScrollOffset(nowOffset: Double, viewportHeight: Double) -> Double {
        max(0, nowOffset - viewportHeight / 4)
    }

    /// いまの線の左に出す数字。iPhone が分だけ (「21」)、iPad が `H:mm` (「15:21」)
    static func nowLineLabel(now: Date, horizontalSizeClassRegular: Bool, calendar: Calendar = GuideLayout.calendar) -> String {
        if horizontalSizeClassRegular {
            return Wording.time(now, calendar: calendar)
        }
        return "\(calendar.component(.minute, from: now))"
    }

    /// `date` が属する放送日 (その日の 4:00)。4:00 より前は前の日の番組表
    static func broadcastDay(for date: Date, calendar: Calendar = GuideLayout.calendar) -> Date {
        let day = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)) ?? date
        let hour = calendar.component(.hour, from: date)
        if hour < broadcastDayStartHour {
            return calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return day
    }

    /// 選んだ日の放送日 (4:00 から翌 4:00) を `from`・`to` に入れて読む範囲 (UNIX ミリ秒)
    static func broadcastRange(for day: Date, calendar: Calendar = GuideLayout.calendar) -> (from: Int64, to: Int64) {
        let start = calendar.date(bySettingHour: broadcastDayStartHour, minute: 0, second: 0, of: day)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    /// 日付のメニューに並べる日。今日から 8 日ぶんで、`until` より先の日は並べない (番組表が無ければ `nil`)
    static func menuDays(now: Date, until: Int64?, calendar: Calendar = GuideLayout.calendar) -> [Date] {
        let today = broadcastDay(for: now, calendar: calendar)
        let days = (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let until else { return days }
        return days.filter { day in
            let range = broadcastRange(for: day, calendar: calendar)
            return range.from < until
        }
    }

    /// TV-Guide の日付のチップの字句。「今日」「明日」「16 (月)」(番組表の行の字句と違い、日付は数字だけ)
    static func dayChipLabel(
        for day: Date,
        today: Date,
        calendar: Calendar = GuideLayout.calendar,
        locale: Locale = .current
    ) -> String {
        let todayStart = broadcastDay(for: today, calendar: calendar)
        if calendar.isDate(day, inSameDayAs: todayStart) {
            return String(localized: LocalizedStringResource("今日", locale: locale))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return String(localized: LocalizedStringResource("明日", locale: locale))
        }
        let number = calendar.component(.day, from: day)
        let weekday = Wording.weekday(of: day, calendar: calendar, locale: locale)
        return String(localized: LocalizedStringResource("\(number) (\(weekday))", locale: locale))
    }

    /// 日付のメニューの字句。「今日 14日 (土)」「15日 (日)」
    static func menuLabel(
        for day: Date,
        today: Date,
        calendar: Calendar = GuideLayout.calendar,
        locale: Locale = .current
    ) -> String {
        let base: String
        if Wording.isJapanese(locale) {
            let dayNumber = calendar.component(.day, from: day)
            base = "\(dayNumber)日 (\(Wording.weekday(of: day, calendar: calendar, locale: locale)))"
        } else {
            base = day.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .day()
                    .weekday(.abbreviated)
            )
        }
        if calendar.isDate(day, inSameDayAs: broadcastDay(for: today, calendar: calendar)) {
            return String(localized: LocalizedStringResource("今日 \(base)", locale: locale))
        }
        return base
    }
}
