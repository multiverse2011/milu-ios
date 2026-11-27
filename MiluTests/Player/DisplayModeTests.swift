import Foundation
import Testing
@testable import Milu

@Suite struct DisplayModeTests {
    @Test func picksTheNearestTelevisionRate() {
        #expect(DisplayMode.refreshRate(frameRate: 23.976) == 23.976)
        #expect(DisplayMode.refreshRate(frameRate: 24) == 24)
        #expect(DisplayMode.refreshRate(frameRate: 25) == 25)
        #expect(DisplayMode.refreshRate(frameRate: 29.97) == 29.97)
        #expect(DisplayMode.refreshRate(frameRate: 30) == 30)
        #expect(DisplayMode.refreshRate(frameRate: 50) == 50)
        #expect(DisplayMode.refreshRate(frameRate: 59.94) == 59.94)
        #expect(DisplayMode.refreshRate(frameRate: 60) == 60)
    }

    @Test func unknownRatesFallBackTo60() {
        // 分からない・コマが無い (0) ときは 60 に頼む
        #expect(DisplayMode.refreshRate(frameRate: 0) == 60)
        #expect(DisplayMode.refreshRate(frameRate: 1) == 60)
        #expect(DisplayMode.refreshRate(frameRate: 120) == 60)
    }

    @Test func rateNotExactlyKnownSnapsToTheNearest() {
        // 29.9 は 29.97、59.5 は 59.94 へ寄せる (画面のモードは標準の値しか無い)
        #expect(DisplayMode.refreshRate(frameRate: 29.9) == 29.97)
        #expect(DisplayMode.refreshRate(frameRate: 59.5) == 59.94)
    }
}
