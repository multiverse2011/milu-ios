import Foundation
import Testing

@testable import Milu

/// tvOS の番組表のフォーカスの動き (TV-Guide) の単体テスト。
struct GuideCursorTests {
    private func service(_ id: Int64, _ programs: [(id: Int64, start: Int64, end: Int64)]) -> GuideService {
        GuideService(
            id: id,
            name: "局\(id)",
            mainId: nil,
            remoteControlKey: Int(id),
            logo: nil,
            programs: programs.map { program in
                GuideProgram(
                    id: program.id,
                    name: "番組\(program.id)",
                    startAt: program.start,
                    endAt: program.end,
                    description: nil,
                    genre: nil,
                    copyNever: false,
                    reservation: nil,
                    recordingId: nil
                )
            }
        )
    }

    /// 局 A は 10:00 から 1 時間ずつ 3 本。局 B は 30 分ずらした 2 本
    private var services: [GuideService] {
        [
            service(1, [(id: 1, start: 10 * 3_600_000, end: 11 * 3_600_000),
                        (id: 2, start: 11 * 3_600_000, end: 12 * 3_600_000),
                        (id: 3, start: 12 * 3_600_000, end: 13 * 3_600_000)]),
            service(2, [(id: 4, start: 10 * 3_600_000 + 1_800_000, end: 11 * 3_600_000 + 1_800_000),
                        (id: 5, start: 11 * 3_600_000 + 1_800_000, end: 12 * 3_600_000 + 1_800_000)]),
        ]
    }

    @Test func initialPicksTheProgramOnAir() {
        #expect(GuideCursorMotion.initial(in: services, now: 10 * 3_600_000 + 1_800_000) == GuideCursor(column: 0, programID: 1))
        // 放送中が無ければ先頭の番組
        #expect(GuideCursorMotion.initial(in: services, now: 9 * 3_600_000) == GuideCursor(column: 0, programID: 1))
        #expect(GuideCursorMotion.initial(in: [], now: 0) == nil)
    }

    @Test func verticalMovesWithinTheColumn() {
        let cursor = GuideCursor(column: 0, programID: 2)
        #expect(GuideCursorMotion.vertical(cursor, in: services, by: 1) == GuideCursor(column: 0, programID: 3))
        #expect(GuideCursorMotion.vertical(cursor, in: services, by: -1) == GuideCursor(column: 0, programID: 1))
        // 端では動かない
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 1), in: services, by: -1) == nil)
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 3), in: services, by: 1) == nil)
    }

    @Test func horizontalKeepsTheSameTime() {
        // 10:00 は局 B では 10:30 の番組の前 → 先頭の番組
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 1), in: services, by: 1) == GuideCursor(column: 1, programID: 4))
        // 11:00 は局 B の 10:30〜11:30 の中
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 2), in: services, by: 1) == GuideCursor(column: 1, programID: 4))
        // 12:00 は局 B の 11:30〜12:30 の中
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 3), in: services, by: 1) == GuideCursor(column: 1, programID: 5))
        // 端では動かない
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 1), in: services, by: -1) == nil)
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4), in: services, by: 1) == nil)
    }

    @Test func initialSkipsEmptyColumns() {
        let empty = service(1, [])
        let filled = service(2, [(id: 7, start: 10 * 3_600_000, end: 11 * 3_600_000)])
        #expect(GuideCursorMotion.initial(in: [empty, filled], now: 10 * 3_600_000 + 60_000) == GuideCursor(column: 1, programID: 7))
        #expect(GuideCursorMotion.initial(in: [empty], now: 0) == nil)
    }

    @Test func horizontalStopsAtAnEmptyColumn() {
        // 隣の局に番組が無ければ、枠は動かさない
        var list = services
        list.append(service(3, []))
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4), in: list, by: 1) == nil)
    }

    @Test func staleCursorIsNotFound() {
        #expect(GuideCursorMotion.program(GuideCursor(column: 0, programID: 99), in: services) == nil)
        #expect(GuideCursorMotion.program(GuideCursor(column: 9, programID: 1), in: services) == nil)
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 99), in: services, by: 1) == nil)
    }
}
