import Foundation
import Testing

@testable import Milu

struct ProgramActionsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute))!
    }

    /// 2026-11-14 15:00。番組は 15:00–15:39 (放送中)・16:00–17:00 (これから)・14:00–14:30 (終わった)
    private let now = Date(timeIntervalSince1970: 1_794_636_000)

    @Test func futureWithoutReservation() {
        let set = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: nil)
        #expect(set == ProgramActionSet(statuses: [], buttons: [.reserve]))
    }

    @Test(arguments: [ReservationState.failed, .missed, .done] as [ReservationState])
    func futureFinishedReservation(state: ReservationState) {
        let set = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: (state, "理由"))
        #expect(set == ProgramActionSet(statuses: [], buttons: [.reserve]))
    }

    @Test func futureScheduledOrRecording() {
        for state in [ReservationState.scheduled, .recording] {
            let set = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: (state, nil))
            #expect(set == ProgramActionSet(statuses: [.reserved], buttons: [.cancelReservation]))
            #expect(set.statuses[0].text == "✓ 予約済み")
        }
    }

    @Test func futureConflict() {
        let set = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: (.conflict, "チューナーが足りません"))
        #expect(set == ProgramActionSet(statuses: [.conflict("チューナーが足りません")], buttons: [.cancelReservation]))
        #expect(set.statuses[0].text == "⚠︎ 競合 · チューナーが足りません")
        // reason が無ければ「⚠︎ 競合」だけ
        let noReason = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: (.conflict, nil))
        #expect(noReason.statuses[0].text == "⚠︎ 競合")
    }

    @Test func futureSkipped() {
        let set = programActions(now: now, startAt: date(hour: 16, minute: 0), endAt: date(hour: 17, minute: 0), reservation: (.skipped, "コピー禁止のため録画しません"))
        #expect(set == ProgramActionSet(statuses: [.reason("コピー禁止のため録画しません")], buttons: [.reserve]))
    }

    /// 局の id が引けない検索の番組は「ライブで観る」を出さない (D31)
    @Test func onAirWithoutServiceHasNoWatchLive() {
        let set = programActions(
            now: now,
            startAt: date(hour: 15, minute: 0),
            endAt: date(hour: 15, minute: 39),
            reservation: nil,
            canWatchLive: false
        )
        #expect(set == ProgramActionSet(statuses: [.onAir(elapsedMs: 0, totalMs: 2_340_000)], buttons: [.record]))
    }

    @Test func onAirWithoutReservation() {
        let set = programActions(now: now, startAt: date(hour: 15, minute: 0), endAt: date(hour: 15, minute: 39), reservation: nil)
        #expect(set == ProgramActionSet(statuses: [.onAir(elapsedMs: 0, totalMs: 2_340_000)], buttons: [.watchLive, .record]))
        #expect(set.statuses[0].text == "放送中 · あと39分")
        #expect(set.showsProgress)
    }

    @Test func onAirReservedOrRecording() {
        for state in [ReservationState.scheduled, .recording] {
            let set = programActions(now: now, startAt: date(hour: 15, minute: 0), endAt: date(hour: 15, minute: 39), reservation: (state, nil))
            #expect(set == ProgramActionSet(statuses: [.onAir(elapsedMs: 0, totalMs: 2_340_000)], buttons: [.watchLive, .recordingNow]))
        }
    }

    @Test func onAirConflict() {
        let set = programActions(now: now, startAt: date(hour: 15, minute: 0), endAt: date(hour: 15, minute: 39), reservation: (.conflict, "チューナーが足りません"))
        #expect(set == ProgramActionSet(
            statuses: [.onAir(elapsedMs: 0, totalMs: 2_340_000), .conflict("チューナーが足りません")],
            buttons: [.watchLive, .cancelReservation]
        ))
    }

    @Test(arguments: [ReservationState.skipped, .failed, .missed, .done] as [ReservationState])
    func onAirFinishedReservation(state: ReservationState) {
        let set = programActions(now: now, startAt: date(hour: 15, minute: 0), endAt: date(hour: 15, minute: 39), reservation: (state, "理由"))
        #expect(set == ProgramActionSet(statuses: [.onAir(elapsedMs: 0, totalMs: 2_340_000)], buttons: [.watchLive, .record]))
    }

    @Test func endedWithoutReason() {
        let set = programActions(now: now, startAt: date(hour: 14, minute: 0), endAt: date(hour: 14, minute: 30), reservation: (.done, nil))
        #expect(set == ProgramActionSet(statuses: [], buttons: []))
    }

    @Test func endedWithReason() {
        let set = programActions(now: now, startAt: date(hour: 14, minute: 0), endAt: date(hour: 14, minute: 30), reservation: (.failed, "録画に失敗しました"))
        #expect(set == ProgramActionSet(statuses: [.reason("録画に失敗しました")], buttons: []))
        // 予約が無くても理由は出す
        let skipped = programActions(now: now, startAt: date(hour: 14, minute: 0), endAt: date(hour: 14, minute: 30), reservation: (.skipped, "コピー禁止"))
        #expect(skipped.statuses == [.reason("コピー禁止")])
    }

    @Test func timingBoundaries() {
        // now == startAt は放送中。now == endAt は終わった
        let atStart = programActions(now: now, startAt: now, endAt: date(hour: 16, minute: 0), reservation: nil)
        #expect(atStart.showsProgress)
        let atEnd = programActions(now: now, startAt: date(hour: 14, minute: 0), endAt: now, reservation: nil)
        #expect(atEnd.buttons.isEmpty)
    }

    @Test func englishTitlesAndStatuses() {
        let en = Locale(identifier: "en_US")
        #expect(ProgramButton.reserve.title(locale: en) == "Schedule Recording")
        #expect(ProgramButton.cancelReservation.title(locale: en) == "Cancel Reservation")
        #expect(ProgramButton.watchLive.title(locale: en) == "Watch Live")
        #expect(ProgramButton.record.title(locale: en) == "● Record")
        #expect(ProgramButton.recordingNow.title(locale: en) == "● Recording")

        #expect(ProgramStatus.reserved.text(locale: en) == "✓ Scheduled")
        #expect(ProgramStatus.conflict("").text(locale: en) == "⚠︎ Conflict")
        #expect(ProgramStatus.conflict("No tuner").text(locale: en) == "⚠︎ Conflict · No tuner")
        #expect(ProgramStatus.onAir(elapsedMs: 0, totalMs: 2_340_000).text(locale: en) == "On Air · 39m left")
    }
}
