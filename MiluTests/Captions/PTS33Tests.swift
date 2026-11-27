import Foundation
import Testing

@testable import Milu

struct PTS33Tests {
    private let cycle = PTS33.cycle // 2^33

    @Test func plainDifferences() {
        #expect(PTS33.difference(5, 3) == 2)
        #expect(PTS33.difference(3, 5) == -2)
        #expect(PTS33.difference(0, 0) == 0)
    }

    @Test func wrapsNearCycleEnd() {
        // 一周の手前とすぐ後ろは近い
        #expect(PTS33.difference(cycle - 3, 10) == -13)
        #expect(PTS33.difference(10, cycle - 3) == 13)
        #expect(PTS33.difference(cycle - 1, 0) == -1)
        #expect(PTS33.difference(0, cycle - 1) == 1)
    }

    @Test func farthestIsHalfCycle() {
        // ちょうど半周は + に取る
        #expect(PTS33.difference(cycle / 2, 0) == Int64(cycle / 2))
        #expect(PTS33.difference(0, cycle / 2) == Int64(cycle / 2))
        // 半周を超えると反対側を取る
        #expect(PTS33.difference(cycle / 2 + 2, 0) == -Int64(cycle / 2 - 2))
    }

    @Test func extendedStaysNearReference() {
        // 手前を一周した値は、reference の周期で負になることもある
        #expect(PTS33.extended(cycle - 3, near: 10) == -3)
        #expect(PTS33.extended(5, near: cycle - 10) == Int64(cycle) + 5)
        #expect(PTS33.extended(100, near: 90) == 100)
        // 伸ばしても 2^33 の剰余は変わらない
        let extended = PTS33.extended(cycle - 3, near: 10)
        let mod = (extended % Int64(cycle) + Int64(cycle)) % Int64(cycle)
        #expect(UInt64(mod) == cycle - 3)
    }
}
