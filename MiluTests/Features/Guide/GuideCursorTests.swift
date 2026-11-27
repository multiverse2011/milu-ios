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
        // 基準の時刻はいま
        #expect(GuideCursorMotion.initial(in: services, now: 10 * 3_600_000 + 1_800_000) == GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000 + 1_800_000))
        // 放送中が無ければ先頭の番組 (いまは番組の外なので、基準はその番組の開始)
        #expect(GuideCursorMotion.initial(in: services, now: 9 * 3_600_000) == GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000))
        #expect(GuideCursorMotion.initial(in: [], now: 0) == nil)
    }

    @Test func verticalMovesWithinTheColumn() {
        let cursor = GuideCursor(column: 0, programID: 2, anchor: 10 * 3_600_000 + 1_800_000)
        // 基準の時刻は移った番組の開始
        #expect(GuideCursorMotion.vertical(cursor, in: services, by: 1) == GuideCursor(column: 0, programID: 3, anchor: 12 * 3_600_000))
        #expect(GuideCursorMotion.vertical(cursor, in: services, by: -1) == GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000))
        // 端では動かない
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000), in: services, by: -1) == nil)
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 3, anchor: 12 * 3_600_000), in: services, by: 1) == nil)
    }

    @Test func horizontalKeepsTheSameTime() {
        // 10:00 は局 B では 10:30 の番組の前 → 先頭の番組
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000), in: services, by: 1) == GuideCursor(column: 1, programID: 4, anchor: 10 * 3_600_000))
        // 11:00 は局 B の 10:30〜11:30 の中
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 2, anchor: 11 * 3_600_000), in: services, by: 1) == GuideCursor(column: 1, programID: 4, anchor: 11 * 3_600_000))
        // 12:00 は局 B の 11:30〜12:30 の中
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 3, anchor: 12 * 3_600_000), in: services, by: 1) == GuideCursor(column: 1, programID: 5, anchor: 12 * 3_600_000))
        // 端では動かない
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 0, programID: 1, anchor: 10 * 3_600_000), in: services, by: -1) == nil)
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4, anchor: 10 * 3_600_000), in: services, by: 1) == nil)
    }

    @Test func horizontalKeepsTheBaseTimeAcrossStations() {
        // 局 B は 9:00 開始の 2 時間枠なので、そこから右へ動くと基準が 9:00 まで遡る。
        // 横に続けて動いても、格子に入ったときの時刻 (10:45) で選ぶ
        let hour: Int64 = 3_600_000
        let stations = [
            service(1, [(id: 1, start: 10 * hour, end: 12 * hour)]),
            service(2, [(id: 2, start: 9 * hour, end: 11 * hour),
                        (id: 3, start: 11 * hour, end: 13 * hour)]),
            service(3, [(id: 4, start: 9 * hour, end: 10 * hour),
                        (id: 5, start: 10 * hour, end: 12 * hour)]),
        ]
        let first = GuideCursorMotion.initial(in: stations, now: 10 * hour + 45 * 60_000)
        #expect(first?.programID == 1)
        let second = first.flatMap { GuideCursorMotion.horizontal($0, in: stations, by: 1) }
        #expect(second?.programID == 2)
        let third = second.flatMap { GuideCursorMotion.horizontal($0, in: stations, by: 1) }
        // 局 B の 9:00 ではなく、入ったときの 10:45 で局 C を選ぶ
        #expect(third?.programID == 5)
    }

    @Test func horizontalAfterVerticalUsesTheMovedProgram() {
        // 上下に動いたら基準の時刻も移った番組の開始になる。そのあとの横移動はその時刻で選ぶ
        let hour: Int64 = 3_600_000
        let stations = [
            service(1, [(id: 1, start: 10 * hour, end: 12 * hour)]),
            service(2, [(id: 2, start: 9 * hour, end: 11 * hour),
                        (id: 3, start: 11 * hour, end: 13 * hour)]),
            service(3, [(id: 4, start: 10 * hour, end: 10 * hour + 50 * 60_000),
                        (id: 5, start: 10 * hour + 50 * 60_000, end: 12 * hour)]),
        ]
        let first = GuideCursorMotion.initial(in: stations, now: 10 * hour + 45 * 60_000)
        let second = first.flatMap { GuideCursorMotion.horizontal($0, in: stations, by: 1) }
        #expect(second?.programID == 2)
        let down = second.flatMap { GuideCursorMotion.vertical($0, in: stations, by: 1) }
        #expect(down == GuideCursor(column: 1, programID: 3, anchor: 11 * hour))
        let next = down.flatMap { GuideCursorMotion.horizontal($0, in: stations, by: 1) }
        // 入ったときの 10:45 ではなく、下がった番組の開始 (11:00) で局 C を選ぶ
        #expect(next?.programID == 5)
    }

    @Test func initialAnchorIsClampedToTheProgram() {
        // いまが全番組より後なら、基準は最後の番組の終わりに丸める
        #expect(GuideCursorMotion.initial(in: services, now: 14 * 3_600_000) == GuideCursor(column: 0, programID: 3, anchor: 13 * 3_600_000))
    }

    @Test func initialSkipsEmptyColumns() {
        let empty = service(1, [])
        let filled = service(2, [(id: 7, start: 10 * 3_600_000, end: 11 * 3_600_000)])
        #expect(GuideCursorMotion.initial(in: [empty, filled], now: 10 * 3_600_000 + 60_000) == GuideCursor(column: 1, programID: 7, anchor: 10 * 3_600_000 + 60_000))
        #expect(GuideCursorMotion.initial(in: [empty], now: 0) == nil)
    }

    @Test func horizontalSkipsEmptyColumns() {
        // 番組の無い局は飛ばす (tvOS の焦点も、番組の無い列には移らない)
        var list = services
        list.append(service(3, []))
        list.append(service(4, [(id: 8, start: 10 * 3_600_000, end: 12 * 3_600_000)]))
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4, anchor: 10 * 3_600_000), in: list, by: 1) == GuideCursor(column: 3, programID: 8, anchor: 10 * 3_600_000))
        // 端に番組が無ければ動かない
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 3, programID: 8, anchor: 10 * 3_600_000), in: list, by: 1) == nil)
    }

    @Test func horizontalSkipsSeveralEmptyColumns() {
        // 番組の無い局が続いても、次の番組のある局まで飛ばす
        var list = services
        list.append(service(3, []))
        list.append(service(4, []))
        list.append(service(5, [(id: 9, start: 10 * 3_600_000, end: 12 * 3_600_000)]))
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4, anchor: 10 * 3_600_000), in: list, by: 1) == GuideCursor(column: 4, programID: 9, anchor: 10 * 3_600_000))
        // 動かさない (delta 0) では何もしない
        #expect(GuideCursorMotion.horizontal(GuideCursor(column: 1, programID: 4, anchor: 10 * 3_600_000), in: list, by: 0) == nil)
    }

    @Test func isUsableTellsColumnsThatCanTakeFocus() {
        var list = services
        list.append(service(3, []))
        #expect(GuideCursorMotion.isUsable(0, in: list))
        // 番組が無い列、範囲の外は焦点を置けない
        #expect(!GuideCursorMotion.isUsable(2, in: list))
        #expect(!GuideCursorMotion.isUsable(-1, in: list))
        #expect(!GuideCursorMotion.isUsable(9, in: list))
    }

    @Test func fallbackCursorGoesToTheNearestUsableColumn() {
        // 使えなくなった列から、左右いちばん近い番組のある列へ移る。基準の時刻は元のまま
        let hour: Int64 = 3_600_000
        let anchor = 10 * hour + 30 * 60_000
        func station(_ id: Int64, _ programID: Int64?) -> GuideService {
            service(id, programID.map { [(id: $0, start: 10 * hour, end: 12 * hour)] } ?? [])
        }
        // 左右どちらにも使える列がある (同じ距離なら左)
        let both = [station(1, 11), station(2, nil), station(3, 12)]
        #expect(GuideCursorMotion.fallbackCursor(from: 1, anchor: anchor, in: both) == GuideCursor(column: 0, programID: 11, anchor: anchor))
        // 左だけ使える
        let leftOnly = [station(1, 21), station(2, nil), station(3, nil)]
        #expect(GuideCursorMotion.fallbackCursor(from: 1, anchor: anchor, in: leftOnly) == GuideCursor(column: 0, programID: 21, anchor: anchor))
        // 右だけ使える
        let rightOnly = [station(1, nil), station(2, nil), station(3, 31)]
        #expect(GuideCursorMotion.fallbackCursor(from: 1, anchor: anchor, in: rightOnly) == GuideCursor(column: 2, programID: 31, anchor: anchor))
        // 局が減って列が範囲外になったら、端の列から近い方へ
        #expect(GuideCursorMotion.fallbackCursor(from: 9, anchor: anchor, in: rightOnly) == GuideCursor(column: 2, programID: 31, anchor: anchor))
        // 使える列が無ければ nil
        #expect(GuideCursorMotion.fallbackCursor(from: 1, anchor: anchor, in: [station(1, nil), station(2, nil)]) == nil)
    }

    @Test func selectedCursorUsesTheHighlightedProgramInItsColumn() {
        // 番組が重なっている所 (1 は 10:00–12:00、2 は 11:00–13:00)。基準の時刻 11:00 から
        // 引き直すと前の番組 (1) を指すが、焦点の列は強調している番組 (2) をそのまま選ぶ
        let overlapping = [service(1, [(id: 1, start: 10 * 3_600_000, end: 12 * 3_600_000),
                                       (id: 2, start: 11 * 3_600_000, end: 13 * 3_600_000)])]
        let cursor = GuideCursor(column: 0, programID: 2, anchor: 11 * 3_600_000)
        #expect(GuideCursorMotion.cursor(at: 0, anchor: cursor.anchor, in: overlapping)?.programID == 1)
        #expect(GuideCursorMotion.selectedCursor(inColumn: 0, from: cursor, in: overlapping) == cursor)
        // ほかの列は基準の時刻から引く
        #expect(GuideCursorMotion.selectedCursor(inColumn: 1, from: cursor, in: services) == GuideCursor(column: 1, programID: 4, anchor: 11 * 3_600_000))
        // 消えた番組を指すカーソルは選ばない
        #expect(GuideCursorMotion.selectedCursor(inColumn: 0, from: GuideCursor(column: 0, programID: 99, anchor: 0), in: overlapping) == nil)
    }

    @Test func staleCursorIsNotFound() {
        #expect(GuideCursorMotion.program(GuideCursor(column: 0, programID: 99, anchor: 0), in: services) == nil)
        #expect(GuideCursorMotion.program(GuideCursor(column: 9, programID: 1, anchor: 0), in: services) == nil)
        #expect(GuideCursorMotion.vertical(GuideCursor(column: 0, programID: 99, anchor: 0), in: services, by: 1) == nil)
    }
}
