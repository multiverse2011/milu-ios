import Foundation

/// tvOS の番組表のフォーカス (TV-Guide)。列が局、`programID` が番組。
struct GuideCursor: Equatable, Sendable {
    let column: Int
    let programID: Int64
}

/// tvOS の番組表でフォーカスを動かす決まり (TV-Guide)。純粋な関数だけを置く。
/// 左右は同じ時刻の隣の局、上下は同じ局の前後の番組。端では動かない (`nil`)。
nonisolated enum GuideCursorMotion {
    /// 開いたときのフォーカス。先頭の局でいま放送中の番組 (無ければ先頭の番組)。
    static func initial(in services: [GuideService], now: Int64) -> GuideCursor? {
        guard let column = services.firstIndex(where: { !$0.programs.isEmpty }),
              let program = nearest(to: now, in: services[column].programs)
        else { return nil }
        return GuideCursor(column: column, programID: program.id)
    }

    /// カーソルの指す番組。読み直しで消えていたら `nil`。
    static func program(_ cursor: GuideCursor, in services: [GuideService]) -> (column: Int, program: GuideProgram)? {
        guard services.indices.contains(cursor.column),
              let program = services[cursor.column].programs.first(where: { $0.id == cursor.programID })
        else { return nil }
        return (cursor.column, program)
    }

    /// 上下。同じ局の前後の番組。
    static func vertical(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard let (column, program) = program(cursor, in: services),
              let index = services[column].programs.firstIndex(where: { $0.id == program.id })
        else { return nil }
        let next = min(max(index + delta, 0), services[column].programs.count - 1)
        guard next != index else { return nil }
        return GuideCursor(column: column, programID: services[column].programs[next].id)
    }

    /// 左右。いまの番組と同じ時刻に入っている番組を隣の局で探す。
    static func horizontal(_ cursor: GuideCursor, in services: [GuideService], by delta: Int) -> GuideCursor? {
        guard let (column, program) = program(cursor, in: services) else { return nil }
        let next = min(max(column + delta, 0), services.count - 1)
        guard next != column, let target = nearest(to: program.startAt, in: services[next].programs) else { return nil }
        return GuideCursor(column: next, programID: target.id)
    }

    /// その時刻に入っている番組。無ければ、その時刻までで最後に始まった番組 (それも無ければ先頭)。
    private static func nearest(to time: Int64, in programs: [GuideProgram]) -> GuideProgram? {
        if let covering = programs.first(where: { $0.startAt <= time && time < $0.endAt }) {
            return covering
        }
        return programs.last { $0.startAt <= time } ?? programs.first
    }
}
