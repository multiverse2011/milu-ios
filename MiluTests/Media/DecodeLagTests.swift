import Foundation
import Testing
@testable import Milu

@Suite struct DecodeLagTests {
    /// 30 コマ/秒の 1 コマ
    private let frame = 1.0 / 30

    @Test func onTimeFramesAreShown() {
        var lag = DecodeLag()
        #expect(lag.frame(pts: 10, end: 10 + frame, now: 9.9) == .show)
        // 表示の時刻を少し過ぎても、コマの終わりの前なら映す
        #expect(lag.frame(pts: 10, end: 10 + frame, now: 10.02) == .show)
    }

    @Test func framesPastTheirEndAreDropped() {
        var lag = DecodeLag()
        #expect(lag.frame(pts: 10, end: 10 + frame, now: 10 + frame) == .drop)
        #expect(lag.frame(pts: 10, end: 10 + frame, now: 10.05) == .drop)
    }

    /// 一瞬の詰まりはデコーダが取り戻すので飛ばない
    @Test func briefLagRecoversWithoutSkipping() {
        var lag = DecodeLag()
        var now = 20.0
        // 0.5 秒のあいだ 0.3 秒遅れて届く
        for i in 0..<15 {
            let pts = 20 + Double(i) * frame
            now = pts + 0.3
            #expect(lag.frame(pts: pts, end: pts + frame, now: now) == .drop)
        }
        // 追いついた
        #expect(lag.frame(pts: now + 0.2, end: now + 0.2 + frame, now: now) == .show)
        // 遅れの始まりは数え直す。また遅れても 1 秒続くまで飛ばない
        let pts = now + 1
        #expect(lag.frame(pts: pts, end: pts + frame, now: pts + 0.3) == .drop)
        #expect(lag.frame(pts: pts, end: pts + frame, now: pts + 1.2) == .drop)
    }

    @Test func sustainedLagSkipsToKeyframeOnce() throws {
        var lag = DecodeLag()
        var actions: [DecodeLag.Action] = []
        // デコーダが追いつかず、遅れが 0.2 秒から広がり続ける
        for i in 0..<45 {
            let pts = 30 + Double(i) * frame
            actions.append(lag.frame(pts: pts, end: pts + frame, now: pts + 0.2 + Double(i) * 0.01))
        }
        let skip = try #require(actions.firstIndex(of: .skipToKeyframe))
        // 遅れはじめてから 1 秒たったところで 1 度だけ
        #expect(actions.filter { $0 == .skipToKeyframe }.count == 1)
        #expect(actions.prefix(skip).allSatisfy { $0 == .drop })
    }

    @Test func resetForgetsEarlierLag() {
        var lag = DecodeLag()
        #expect(lag.frame(pts: 40, end: 40 + frame, now: 40.5) == .drop)
        lag.reset()
        // reset の前の遅れから数えない
        #expect(lag.frame(pts: 41, end: 41 + frame, now: 41.6) == .drop)
        #expect(lag.frame(pts: 42, end: 42 + frame, now: 42.5) == .drop)
    }
}
