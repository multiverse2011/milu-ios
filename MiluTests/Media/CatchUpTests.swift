import Foundation
import Testing
@testable import Milu

@Suite struct CatchUpTests {
    @Test func overTenSecondsFlushes() {
        #expect(CatchUp.action(ahead: 10.01, rate: 1) == .flushToKeyframe)
        #expect(CatchUp.action(ahead: 12, rate: 1.05) == .flushToKeyframe)
    }

    @Test func overFourSecondsSpeedsUpOnce() {
        #expect(CatchUp.action(ahead: 4.01, rate: 1) == .setRate(1.05))
        #expect(CatchUp.action(ahead: 10, rate: 1) == .setRate(1.05))
        // 実機の synchronizer.rate は Float。Float(1.05) のまま比べられること
        #expect(CatchUp.action(ahead: 6, rate: Float(1.05)) == .keep)
        #expect(CatchUp.action(ahead: 4, rate: 1) == .keep)
    }

    @Test func underFourThirdsReturnsToOne() {
        #expect(CatchUp.action(ahead: 1, rate: 1.05) == .setRate(1))
        #expect(CatchUp.action(ahead: 1, rate: 1) == .keep)
        #expect(CatchUp.action(ahead: 4.0 / 3.0, rate: 1.05) == .keep)
    }
}
