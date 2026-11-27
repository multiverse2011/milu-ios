import Foundation

/// 時刻と長さの書き方 (3.5・3.5.3)。どの画面もこの関数から出す。
enum Wording {
    nonisolated static func isJapanese(_ locale: Locale) -> Bool {
        locale.language.languageCode == .japanese
    }

    /// 時刻は 24 時間の `H:mm`
    nonisolated static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return "\(hour):" + (minute < 10 ? "0\(minute)" : "\(minute)")
    }

    /// 長さは 60 分未満が「n分」、ちょうどの時間が「n時間」、ほかは「n時間m分」。分未満は四捨五入。
    nonisolated static func duration(_ ms: Int64, locale: Locale = .current) -> String {
        durationMinutes(minutes(of: ms, rule: .toNearestOrAwayFromZero), locale: locale)
    }

    /// 「あとn分」「残りn分」。分に切り上げ、長さと同じ書き方 (3.5)。
    nonisolated static func remaining(_ ms: Int64, kind: RemainingKind, locale: Locale = .current) -> String {
        let text = durationMinutes(minutes(of: ms, rule: .up), locale: locale)
        return switch kind {
        case .ago: String(localized: LocalizedStringResource("あと\(text)", locale: locale))
        case .left: String(localized: LocalizedStringResource("残り\(text)", locale: locale))
        }
    }

    enum RemainingKind: Sendable {
        case ago
        case left
    }

    /// 位置は 1 時間未満が `m:ss`、1 時間以上が `h:mm:ss` (3.5.3)
    nonisolated static func position(_ ms: Int64) -> String {
        let total = max(0, ms) / 1000
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        let ss = second < 10 ? "0\(second)" : "\(second)"
        guard hour > 0 else { return "\(minute):" + ss }
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(hour):\(mm):\(ss)"
    }

    /// 日付は日本語なら `M/d (E)` (「11/14 (土)」)、それ以外はロケールに合わせた短い日付と曜日。
    nonisolated static func dateShort(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if isJapanese(locale) {
            return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date)) (\(weekday(of: date, calendar: calendar, locale: locale)))"
        }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.defaultDigits)
                .day()
                .weekday(.abbreviated)
        )
    }

    /// 録画の一覧の見出しの主部と副部 (3.5)。日本語は「今日」+「11月14日 (土)」/「11月12日」+「(木)」。
    nonisolated static func dateHeadingParts(
        _ date: Date,
        reference: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> (primary: String, secondary: String) {
        if isJapanese(locale) {
            let monthDay = "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
            let wd = "(\(weekday(of: date, calendar: calendar, locale: locale)))"
            let base = "\(monthDay) \(wd)"
            if calendar.isDate(date, inSameDayAs: reference) {
                return (String(localized: LocalizedStringResource("今日", locale: locale)), base)
            }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
               calendar.isDate(date, inSameDayAs: yesterday) {
                return (String(localized: LocalizedStringResource("昨日", locale: locale)), base)
            }
            return (monthDay, wd)
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let full = date.formatted(style.month(.abbreviated).day().weekday(.abbreviated))
        if calendar.isDate(date, inSameDayAs: reference) {
            return (String(localized: LocalizedStringResource("今日", locale: locale)), "· \(full)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return (String(localized: LocalizedStringResource("昨日", locale: locale)), "· \(full)")
        }
        let monthDay = date.formatted(style.month(.abbreviated).day())
        let wd = date.formatted(style.weekday(.abbreviated))
        return (monthDay, wd)
    }

    /// 時刻の範囲の区切り (3.5.3)。ライブのタブと番組の詳細が「–」、録画・追っかけ・全画面の再生が「〜」
    enum RangeSeparator: String, Sendable {
        case live = "–"
        case recording = "〜"
    }

    /// 「15:00–15:30」
    nonisolated static func timeRange(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current,
        separator: RangeSeparator,
        locale: Locale = .current
    ) -> String {
        let sep = separator == .live
            ? RangeSeparator.live.rawValue
            : String(localized: LocalizedStringResource("〜", locale: locale))
        return time(start, calendar: calendar) + sep + time(end, calendar: calendar)
    }

    nonisolated static func weekday(of date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: String(localized: LocalizedStringResource("日", locale: locale))
        case 2: String(localized: LocalizedStringResource("月", locale: locale))
        case 3: String(localized: LocalizedStringResource("火", locale: locale))
        case 4: String(localized: LocalizedStringResource("水", locale: locale))
        case 5: String(localized: LocalizedStringResource("木", locale: locale))
        case 6: String(localized: LocalizedStringResource("金", locale: locale))
        default: String(localized: LocalizedStringResource("土", locale: locale))
        }
    }

    nonisolated static func minutes(of ms: Int64, rule: FloatingPointRoundingRule) -> Int {
        max(0, Int((Double(max(0, ms)) / 60_000).rounded(rule)))
    }

    nonisolated static func durationMinutes(_ minutes: Int, locale: Locale = .current) -> String {
        if minutes < 60 { return String(localized: LocalizedStringResource("\(minutes)分", locale: locale)) }
        if minutes % 60 == 0 { return String(localized: LocalizedStringResource("\(minutes / 60)時間", locale: locale)) }
        return String(localized: LocalizedStringResource("\(minutes / 60)時間\(minutes % 60)分", locale: locale))
    }
}

extension Wording {
    /// 録画の一覧の行・カードの組み立てに要る入力 (一覧の行のうち表示に関わる分)
    struct RecordingListEntry: Equatable, Sendable {
        var startAt: Date
        /// EPG の終了時刻。録画中の「あと n 分」に使う
        var endAt: Date
        var serviceName: String
        /// いま録っている最中か。一覧 API の `recording`
        var recording: Bool
        /// 録画中は `null`
        var durationMs: Int64?
        /// 途中まで観た位置。観ていなければ `null`
        var resumeMs: Int64?

        nonisolated init(startAt: Date, endAt: Date, serviceName: String, recording: Bool, durationMs: Int64?, resumeMs: Int64?) {
            self.startAt = startAt
            self.endAt = endAt
            self.serviceName = serviceName
            self.recording = recording
            self.durationMs = durationMs
            self.resumeMs = resumeMs
        }
    }

    /// 録画の一覧の日付の区切り (3.5)。`startAt` の日付 (端末の時間帯) ごとに区切り、新しい順。
    struct DateSection<Element: Sendable> {
        nonisolated var date: Date
        nonisolated var entries: [Element]

        nonisolated init(date: Date, entries: [Element]) {
            self.date = date
            self.entries = entries
        }
    }

    /// iPhone の録画の一覧の行の 2 段目と 3 段目 (3.5)。3 段目は録画中だけ。
    nonisolated static func listRowSubtitles(
        _ entry: RecordingListEntry,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> (second: String, third: String?) {
        let head = time(entry.startAt, calendar: calendar)
        if entry.recording {
            let left = Int64(entry.endAt.timeIntervalSince(now) * 1000)
            let rem = remaining(left, kind: .ago, locale: locale)
            return ("\(head) · \(entry.serviceName)", String(localized: LocalizedStringResource("● 録画中 · \(rem)", locale: locale)))
        }
        if let resumeMs = entry.resumeMs {
            let left = effectiveDurationMs(of: entry) - resumeMs
            let rem = remaining(left, kind: .left, locale: locale)
            return ("\(head) · \(entry.serviceName) · \(rem)", nil)
        }
        let len = duration(effectiveDurationMs(of: entry), locale: locale)
        return ("\(head) · \(len) · \(entry.serviceName)", nil)
    }

    /// 横長の iPad のカードの 2 段目 (3.5)。3 段目は無い。
    nonisolated static func cardSubtitle(
        _ entry: RecordingListEntry,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let head = time(entry.startAt, calendar: calendar)
        if entry.recording {
            let left = Int64(entry.endAt.timeIntervalSince(now) * 1000)
            let rem = remaining(left, kind: .ago, locale: locale)
            return "\(head) · \(entry.serviceName) · \(rem)"
        }
        let len = duration(effectiveDurationMs(of: entry), locale: locale)
        let base = "\(head) · \(len) · \(entry.serviceName)"
        if let resumeMs = entry.resumeMs {
            let rem = remaining(effectiveDurationMs(of: entry) - resumeMs, kind: .left, locale: locale)
            return "\(base) · \(rem)"
        }
        return base
    }

    /// 録画の一覧を日付の区切りに分ける。新しい順。
    nonisolated static func sections<Element: Sendable>(of entries: [Element], startAt: (Element) -> Date, reference: Date, calendar: Calendar = .current) -> [DateSection<Element>] {
        var grouped: [(date: Date, entries: [Element])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: startAt(entry))
            if let index = grouped.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
                grouped[index].entries.append(entry)
            } else {
                grouped.append((date: day, entries: [entry]))
            }
        }
        return grouped
            .sorted { $0.date > $1.date }
            .map { DateSection(date: $0.date, entries: $0.entries) }
    }

    /// 録画中で `durationMs` が無いときは EPG の予定の長さで足す
    nonisolated static func effectiveDurationMs(of entry: RecordingListEntry) -> Int64 {
        entry.durationMs ?? Int64(entry.endAt.timeIntervalSince(entry.startAt) * 1000)
    }
}
