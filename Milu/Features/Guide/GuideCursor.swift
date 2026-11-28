import Foundation

/// tvOS の番組表のフォーカス (TV-Guide)。空の時刻では列と基準時刻だけを持つ。
struct GuideCursor: Equatable, Sendable {
    let column: Int
    let programID: Int64?
    /// 横に動くときの基準の時刻 (UNIX ミリ秒)。横に続けて動いても変えない
    let anchor: Int64
}

/// tvOS の番組表でフォーカスを動かす決まり (TV-Guide)。純粋な関数だけを置く。
/// 左右は基準の時刻 (`anchor`) に入っている隣の局の番組、上下は同じ局の前後の番組。
/// 上下に動いたら基準の時刻も移った番組の開始に合わせ直す (純正の番組表と同じ)。
/// 端では動かない (`nil`)。
nonisolated enum GuideCursorMotion {
    /// 開いたときのフォーカス。先頭の局で、いま放送中の番組。無ければ、いままでで最後に始まった
    /// 番組 (それも無ければ先頭の番組)。
    /// 基準の時刻はいま。他の日を出しているときはいまが番組の外なので、その番組の端にする
    static func initial(in services: [GuideService], now: Int64) -> GuideCursor? {
        guard let column = services.firstIndex(where: { !$0.programs.isEmpty }),
              let program = nearest(to: now, in: services[column].programs)
        else { return nil }
        return GuideCursor(
            column: column,
            programID: program.id,
            anchor: min(max(now, program.startAt), program.endAt)
        )
    }

    /// カーソルの指す番組。読み直しで消えていたら `nil`。
    static func program(_ cursor: GuideCursor, in services: [GuideService]) -> (column: Int, program: GuideProgram)? {
        guard services.indices.contains(cursor.column) else { return nil }
        let programs = services[cursor.column].programs
        guard let index = programIndex(cursor, in: programs) else { return nil }
        return (cursor.column, programs[index])
    }

    /// 番組のある局の指定時刻に置く。その時刻に放送がなければ番組 ID は空のまま。
    static func cursor(at column: Int, anchor: Int64, in services: [GuideService]) -> GuideCursor? {
        guard isUsable(column, in: services) else { return nil }
        let program = services[column].programs.first { $0.startAt <= anchor && anchor < $0.endAt }
        return GuideCursor(column: column, programID: program?.id, anchor: anchor)
    }

    /// 同じ局・番組を優先する。番組自体が外れたら、残るマスの中に基準時刻を置く。
    static func cursorAfterRefresh(
        _ cursor: GuideCursor, previous: [GuideService], current: [GuideService], range: Range<Int64>, hasResponse: Bool = true
    ) -> GuideCursor? {
        guard !range.isEmpty else { return nil }
        let serviceID = previous.indices.contains(cursor.column) ? previous[cursor.column].id : nil
        let column = current.firstIndex { $0.id == serviceID } ?? cursor.column
        let remapped = GuideCursor(column: column, programID: cursor.programID, anchor: cursor.anchor)
        if range.contains(cursor.anchor) {
            if cursor.programID == nil || !hasResponse {
                return Self.cursor(at: column, anchor: cursor.anchor, in: current)
                    ?? emptyFallbackCursor(from: column, anchor: cursor.anchor, in: current)
            }
            if let (_, program) = Self.program(remapped, in: current) {
                if program.startAt <= cursor.anchor, cursor.anchor < program.endAt { return remapped }
                if let covering = Self.cursor(at: column, anchor: cursor.anchor, in: current), covering.programID != nil {
                    return covering
                }
                return remapped
            }
        }
        let anchor = min(max(cursor.anchor, range.lowerBound), range.upperBound - 1)
        guard let target = isUsable(column, in: current) ? column : fallbackCursor(from: column, anchor: anchor, in: current)?.column,
              let program = nearest(to: anchor, in: current[target].programs)
        else { return nil }
        let start = max(range.lowerBound, program.startAt)
        let end = min(range.upperBound, program.endAt)
        guard start < end else { return nil }
        return GuideCursor(column: target, programID: program.id, anchor: min(max(anchor, start), end - 1))
    }

    /// その列で選ぶ (決定で開く) カーソル。焦点の列なら、強調しているカーソルそのもの。
    /// 基準の時刻から引き直すと、番組が重なっている所や、基準の時刻が番組の外にあるときに
    /// 別の番組を指すことがある。ほかの列は基準の時刻から引く。
    static func selectedCursor(inColumn column: Int, from cursor: GuideCursor, in services: [GuideService]) -> GuideCursor? {
        if cursor.column == column {
            return program(cursor, in: services) == nil ? nil : cursor
        }
        guard let candidate = Self.cursor(at: column, anchor: cursor.anchor, in: services), candidate.programID != nil else { return nil }
        return candidate
    }

    /// 上下。同じ局の前後の番組。基準の時刻は移った番組の開始にする。
    static func vertical(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard delta != 0, services.indices.contains(cursor.column) else { return nil }
        let programs = services[cursor.column].programs
        let target: GuideProgram?
        if cursor.programID == nil {
            target = delta < 0 ? programs.last { $0.startAt < cursor.anchor } : programs.first { $0.startAt >= cursor.anchor }
        } else if let index = programIndex(cursor, in: programs) {
            let next = min(max(index + delta, 0), programs.count - 1)
            target = next == index ? nil : programs[next]
        } else {
            target = nil
        }
        return target.map { GuideCursor(column: cursor.column, programID: $0.id, anchor: $0.startAt) }
    }

    /// 左右。基準の時刻に入っている番組を `delta` だけ先の局で探す。番組の無い局は飛ばす。
    /// tvOS の焦点が移った列を渡すときは、いまの列との差を `delta` にする。
    static func horizontal(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard services.indices.contains(cursor.column),
              let next = adjacentColumn(from: cursor.column, in: services, by: delta)
        else { return nil }
        if cursor.programID == nil { return Self.cursor(at: next, anchor: cursor.anchor, in: services) }
        guard program(cursor, in: services) != nil else { return nil }
        let program = nearest(to: cursor.anchor, in: services[next].programs)
        return GuideCursor(column: next, programID: program?.id, anchor: cursor.anchor)
    }

    /// 同じ番組が未取得日を挟む場合は、基準時刻に対応する側のマスを選ぶ。
    private static func programIndex(_ cursor: GuideCursor, in programs: [GuideProgram]) -> Int? {
        guard let id = cursor.programID else { return nil }
        return programs.firstIndex { $0.id == id && $0.startAt <= cursor.anchor && cursor.anchor < $0.endAt }
            ?? programs.lastIndex { $0.id == id && $0.startAt <= cursor.anchor }
            ?? programs.firstIndex { $0.id == id }
    }

    /// 隣の、番組のある列。無ければ `nil`。
    static func adjacentColumn(from column: Int, in services: [GuideService], by delta: Int) -> Int? {
        guard delta != 0 else { return nil }
        var next = column + delta
        while services.indices.contains(next), !isUsable(next, in: services) {
            next += delta
        }
        return isUsable(next, in: services) ? next : nil
    }

    /// 焦点を置ける列か (列があり、番組が 1 つ以上ある)。
    static func isUsable(_ column: Int, in services: [GuideService]) -> Bool {
        services.indices.contains(column) && !services[column].programs.isEmpty
    }

    /// 使えなくなった列 (番組が消えた・局が減った) から戻る代わり。いちばん近い番組のある列で、
    /// 基準の時刻 (`anchor`) は元のまま。同じ距離なら左の列。
    static func fallbackCursor(from column: Int, anchor: Int64, in services: [GuideService]) -> GuideCursor? {
        guard !services.isEmpty else { return nil }
        let start = min(max(0, column), services.count - 1)
        for step in 0..<services.count {
            for next in [start - step, start + step] where isUsable(next, in: services) {
                return cursor(at: next, anchor: anchor, in: services)
            }
        }
        return nil
    }

    /// 空の時刻から復帰するときは、近い利用可能列へ選択を変えずに移す。
    private static func emptyFallbackCursor(from column: Int, anchor: Int64, in services: [GuideService]) -> GuideCursor? {
        fallbackCursor(from: column, anchor: anchor, in: services).map {
            GuideCursor(column: $0.column, programID: nil, anchor: anchor)
        }
    }

    /// 読み直しで番組が消えたら、残った番組とその中の基準時刻に置き直す。
    static func repairedCursor(
        _ cursor: GuideCursor?, from column: Int, anchor: Int64, in services: [GuideService]
    ) -> GuideCursor? {
        if let cursor {
            if program(cursor, in: services) != nil { return cursor }
            if cursor.programID == nil {
                return Self.cursor(at: cursor.column, anchor: cursor.anchor, in: services)
                    ?? emptyFallbackCursor(from: column, anchor: cursor.anchor, in: services)
            }
        }
        guard let replacement = fallbackCursor(from: column, anchor: anchor, in: services),
              let program = nearest(to: anchor, in: services[replacement.column].programs) else { return nil }
        let last = program.endAt > program.startAt ? program.endAt - 1 : program.startAt
        return GuideCursor(
            column: replacement.column, programID: program.id,
            anchor: min(max(anchor, program.startAt), last)
        )
    }

    /// その時刻に入っている番組。無ければ、その時刻までで最後に始まった番組 (それも無ければ先頭)。
    private static func nearest(to time: Int64, in programs: [GuideProgram]) -> GuideProgram? {
        if let covering = programs.first(where: { $0.startAt <= time && time < $0.endAt }) {
            return covering
        }
        return programs.last { $0.startAt <= time } ?? programs.first
    }
}
