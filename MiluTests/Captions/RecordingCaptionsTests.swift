import Foundation
import Testing
@testable import Milu

@Suite @MainActor struct RecordingCaptionsTests {
    private var page: CaptionPage {
        CaptionPage(
            v: 1,
            plane: [960, 540],
            duration: 1000,
            runs: [
                CaptionRun(
                    x: 170, y: 450, w: 40, h: 60, fx: 2, fy: 12, size: 36,
                    scaleX: 1, text: "あ", fg: "#ffffffff", bg: "#00000080"
                )
            ],
            drcs: nil
        )
    }

    @Test func rebuiltShowsTheLastPageOnOrBeforeThePosition() {
        let pages = [
            RecordingCaptionPage(at: 10, page: page),
            RecordingCaptionPage(at: 20, page: page),
        ]
        let atTen = CaptionTimeline.rebuilt(from: pages, position: 10)
        #expect(atTen.page(at: 10_500) != nil)
        let before = CaptionTimeline.rebuilt(from: pages, position: 9)
        #expect(before.page(at: 9_500) == nil)
    }

    @Test func rebuiltHonoursThePageDuration() {
        let timeline = CaptionTimeline.rebuilt(
            from: [RecordingCaptionPage(at: 10, page: page)],
            position: 10.5
        )
        #expect(timeline.page(at: 10_900) != nil)
        #expect(timeline.page(at: 11_100) == nil)
    }
}
