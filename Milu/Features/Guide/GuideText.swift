import Foundation

/// 番組表の画面に出す字句 (3.5・画面案)。純粋な関数だけを置く。
nonisolated enum GuideText {
    /// 種別の Picker に出す名前。地上波・BS・CS・ケーブル・スカパー の順で並べる (3.5)
    static func typeLabel(_ type: ServiceType, locale: Locale = .current) -> String {
        switch type {
        case .GR: String(localized: LocalizedStringResource("地上波", locale: locale))
        case .BS: String(localized: LocalizedStringResource("BS", locale: locale))
        case .CS: String(localized: LocalizedStringResource("CS", locale: locale))
        case .CATV: String(localized: LocalizedStringResource("ケーブル", locale: locale))
        case .SKY: String(localized: LocalizedStringResource("スカパー", locale: locale))
        }
    }

    /// 番組の詳細の頭の行。「BSみなと · 今日 16:00–17:00」(今日でなければ日付) (3.5)
    static func sheetHeader(
        serviceName: String,
        startAt: Date,
        endAt: Date,
        now: Date,
        calendar: Calendar = GuideLayout.calendar,
        locale: Locale = .current
    ) -> String {
        let day = calendar.isDate(startAt, inSameDayAs: now)
            ? String(localized: LocalizedStringResource("今日", locale: locale))
            : Wording.dateShort(startAt, calendar: calendar, locale: locale)
        let range = Wording.timeRange(from: startAt, to: endAt, calendar: calendar, separator: .live, locale: locale)
        return "\(serviceName) · \(day) \(range)"
    }

    /// extended の項目。「番組内容」「出演者」を先に、残りは見出しの辞書順 (3.5.3)。
    /// JSON のキーの順に頼らない。
    static func extendedItems(_ extended: [String: String]) -> [(heading: String, body: String)] {
        let preferred = ["番組内容", "出演者"]
        var items: [(heading: String, body: String)] = []
        for key in preferred {
            if let body = extended[key] {
                items.append((key, body))
            }
        }
        for key in extended.keys.sorted() where !preferred.contains(key) {
            items.append((key, extended[key] ?? ""))
        }
        return items
    }

    /// extended の項目の見出し。既知のキー (番組内容・出演者) だけ文脈付きで訳し、未知のキーはそのまま返す。
    static func extendedHeading(_ key: String, locale: Locale = .current) -> String {
        switch key {
        case "番組内容":
            String(localized: LocalizedStringResource("番組内容 (見出し)", defaultValue: "番組内容", locale: locale))
        case "出演者":
            String(localized: LocalizedStringResource("出演者 (見出し)", defaultValue: "出演者", locale: locale))
        default:
            key
        }
    }

    /// マスに入る行の数 (3.5・milu.css の .cell)。
    ///
    /// 行の高さと余白は画面案から (`padding 5px 6px`・`gap 2px`・`.h` は 12.5px/1.35・`.ds` と `.rs` は 11px/1.35)。
    /// 行の途中で切らないよう、入る行だけを出して最後の行を「…」で終える。1 行も入らないマスは何も出さない。
    static func cellLines(height: Double, hasBadge: Bool) -> GuideCellLines {
        // 実の字の高さは 1.35 より少し大きいので、行に余裕を持たせ、下にも 2pt 残す
        let titleLine = 18.0
        let detailLine = 15.5
        let spacing = 2.0
        let available = height - 10 - 2
        guard available >= titleLine else {
            return GuideCellLines(title: 0, showsBadge: false, description: 0)
        }
        let badgeSpan = hasBadge ? spacing + detailLine : 0
        let titleLines = available >= 2 * titleLine + badgeSpan + spacing + detailLine ? 2 : 1
        var remaining = available - Double(titleLines) * titleLine
        var showsBadge = false
        if hasBadge, remaining >= spacing + detailLine {
            showsBadge = true
            remaining -= spacing + detailLine
        }
        let descriptionLines = remaining >= spacing + detailLine
            ? Int((remaining - spacing) / detailLine)
            : 0
        return GuideCellLines(title: titleLines, showsBadge: showsBadge, description: descriptionLines)
    }

    /// マスの予約の印。scheduled なら予約済み、recording なら録画中、conflict なら競合 (3.5)
    static func cellBadges(reservation: ReservationInfo?) -> [GuideCellBadge] {
        guard let state = reservation?.state else { return [] }
        switch state {
        case .scheduled:
            return [.reserved]
        case .recording:
            return [.recording]
        case .conflict:
            return [.conflict]
        case .skipped, .failed, .missed, .done:
            return []
        }
    }

    static let tvCellVerticalPadding = 10.0
    private static let tvTitleLineHeight = 34.0

    /// tvOS のマスに入る行の数 (TV-Guide)。題は 25pt・行 34pt、説明は 21pt・行 30pt、上下の余白 20pt、行の間 4pt。
    /// iPhone/iPad と違い、予約の印は題の行に並べるので、印のぶんの行は取らない。
    static func tvCellLines(height: Double, textScale: Double = 1) -> (title: Int, description: Int) {
        let titleLine = tvTitleLineHeight * textScale
        let detailLine = 30 * textScale
        let spacing = 4.0
        let available = height - 2 * tvCellVerticalPadding
        guard available >= titleLine else { return (0, 0) }
        let titleLines = available >= 2 * titleLine + spacing + detailLine ? 2 : 1
        let remaining = available - Double(titleLines) * titleLine
        let description = remaining >= spacing + detailLine
            ? Int((remaining - spacing) / detailLine)
            : 0
        return (titleLines, description)
    }

    static func tvCellHeadingHeight(titleLines: Int, textScale: Double) -> Double {
        guard titleLines > 0 else { return 0 }
        return 2 * tvCellVerticalPadding + Double(titleLines) * tvTitleLineHeight * textScale
    }
}

/// マスに入る行の数 (題・予約の印・説明)。
struct GuideCellLines: Equatable, Sendable {
    var title: Int
    var showsBadge: Bool
    var description: Int
}

/// マスに出す印 1 つ。「予約済み」は tint、「● 録画中」は赤、「⚠︎ 競合」は橙 (3.5 の色の表)。
/// 色の対応は画面側でする。
enum GuideCellBadge: Equatable, Sendable {
    case reserved
    case recording
    case conflict

    var text: String { text() }

    func text(locale: Locale = .current) -> String {
        switch self {
        case .reserved: String(localized: LocalizedStringResource("予約済み", locale: locale))
        case .recording: String(localized: LocalizedStringResource("● 録画中", locale: locale))
        case .conflict: String(localized: LocalizedStringResource("⚠︎ 競合", locale: locale))
        }
    }
}
