import Foundation

/// tvOS の番組表のフォーカス (TV-Guide)。列が局、`programID` が番組。
struct GuideCursor: Equatable, Sendable {
    let column: Int
    let programID: Int64
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
        guard services.indices.contains(cursor.column),
              let program = services[cursor.column].programs.first(where: { $0.id == cursor.programID })
        else { return nil }
        return (cursor.column, program)
    }

    /// 指定の局で、基準の時刻に入っている番組。
    static func cursor(at column: Int, anchor: Int64, in services: [GuideService]) -> GuideCursor? {
        guard services.indices.contains(column),
              let program = nearest(to: anchor, in: services[column].programs)
        else { return nil }
        return GuideCursor(column: column, programID: program.id, anchor: anchor)
    }

    /// 上下。同じ局の前後の番組。基準の時刻は移った番組の開始にする。
    static func vertical(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard let (column, program) = program(cursor, in: services),
              let index = services[column].programs.firstIndex(where: { $0.id == program.id })
        else { return nil }
        let next = min(max(index + delta, 0), services[column].programs.count - 1)
        guard next != index else { return nil }
        let target = services[column].programs[next]
        return GuideCursor(column: column, programID: target.id, anchor: target.startAt)
    }

    /// 左右。基準の時刻に入っている番組を `delta` だけ先の局で探す。番組の無い局は飛ばす。
    /// tvOS の焦点が移った列を渡すときは、いまの列との差を `delta` にする。
    static func horizontal(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard let (column, _) = program(cursor, in: services),
              let next = adjacentColumn(from: column, in: services, by: delta)
        else { return nil }
        return Self.cursor(at: next, anchor: cursor.anchor, in: services)
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

    /// その時刻に入っている番組。無ければ、その時刻までで最後に始まった番組 (それも無ければ先頭)。
    private static func nearest(to time: Int64, in programs: [GuideProgram]) -> GuideProgram? {
        if let covering = programs.first(where: { $0.startAt <= time && time < $0.endAt }) {
            return covering
        }
        return programs.last { $0.startAt <= time } ?? programs.first
    }
}
