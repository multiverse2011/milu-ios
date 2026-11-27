import Foundation
import Testing

@testable import Milu

/// CaptionTimeline (いつ何を出すか) の単体テスト。
struct CaptionTimelineTests {
    private func run(text: String = "字幕", flash: Bool? = nil) -> CaptionRun {
        CaptionRun(x: 0, y: 0, w: 40, h: 60, fx: 2, fy: 12, size: 36, scaleX: 1, text: text, joined: nil, drcs: nil, fg: "#ffffffff", bg: "#00000080", stroke: nil, underline: nil, bold: nil, italic: nil, box: nil, flash: flash, ruby: nil)
    }

    private func page(runs: [CaptionRun], duration: Int? = nil, v: Int = 1) -> CaptionPage {
        CaptionPage(v: v, plane: [960, 540], duration: duration, runs: runs, drcs: nil)
    }

    @Test func newPageReplacesPrevious() {
        var timeline = CaptionTimeline()
        let first = page(runs: [run()])
        timeline.show(first, at: 1000)
        #expect(timeline.page(at: 1000) == first)
        // 新しい 1 枚が来たら前の 1 枚を丸ごと置き換える
        let second = page(runs: [run(text: "次")])
        timeline.show(second, at: 2000)
        #expect(timeline.page(at: 2000) == second)
    }

    @Test func emptyRunsClears() {
        var timeline = CaptionTimeline()
        timeline.show(page(runs: [run()]), at: 1000)
        // runs が空の 1 枚は消す
        timeline.show(page(runs: []), at: 2000)
        #expect(timeline.page(at: 2000) == nil)
    }

    @Test func nilClears() {
        var timeline = CaptionTimeline()
        timeline.show(page(runs: [run()]), at: 1000)
        timeline.show(nil, at: 2000)
        #expect(timeline.page(at: 2000) == nil)
    }

    @Test func durationExpiresPage() {
        var timeline = CaptionTimeline()
        timeline.show(page(runs: [run()], duration: 3000), at: 1000)
        #expect(timeline.page(at: 3999) != nil)
        // 指定した時間がたったら、次を待たずに消す
        #expect(timeline.page(at: 4000) == nil)
    }

    @Test func nullDurationStaysUntilNext() {
        var timeline = CaptionTimeline()
        timeline.show(page(runs: [run()], duration: nil), at: 1000)
        #expect(timeline.page(at: 60_000) != nil)
    }

    @Test func unsupportedVersionIsIgnored() {
        var timeline = CaptionTimeline()
        let known = page(runs: [run()])
        timeline.show(known, at: 1000)
        // v が 1 でない 1 枚は捨てる (いま出しているものは替わらない)
        timeline.show(page(runs: [run(text: "将来の形式")], v: 2), at: 2000)
        #expect(timeline.page(at: 2000) == known)
    }

    @Test func flashHidesRunEveryHalfSecond() {
        var timeline = CaptionTimeline()
        let flashing = run(flash: true)
        timeline.show(page(runs: [flashing, run(text: "常灯")]), at: 0)
        // 0.5 秒ずつ点滅する (絶対時計の位相)
        #expect(!timeline.isHidden(flashing, at: 0))
        #expect(timeline.isHidden(flashing, at: 500))
        #expect(!timeline.isHidden(flashing, at: 1000))
        #expect(!timeline.isHidden(flashing, at: 1499))
        #expect(timeline.isHidden(flashing, at: 1500))
        // flash でない run は消えない
        #expect(!timeline.isHidden(run(text: "常灯"), at: 500))
    }
}
