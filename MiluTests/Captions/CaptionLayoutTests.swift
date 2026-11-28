import CoreGraphics
import Foundation
import Testing

@testable import Milu

/// CaptionLayout (面から枠への写し方・区画の置き方) の単体テスト。
struct CaptionLayoutTests {
    private let run = CaptionRun(
        x: 250, y: 450, w: 40, h: 60,
        fx: 2, fy: 12,
        size: 36, scaleX: 1,
        text: "字幕です",
        joined: nil, drcs: nil,
        fg: "#ffffffff", bg: "#00000080",
        stroke: nil, underline: nil, bold: nil, italic: nil, box: nil, flash: nil, ruby: nil
    )

    @Test func planeScalesToFrame() {
        // 面を枠に縦横それぞれ伸ばす
        #expect(CaptionLayout.scaleX(planeWidth: 960, frameWidth: 1920) == 2)
        #expect(CaptionLayout.scaleY(planeHeight: 540, frameHeight: 1080) == 2)
        #expect(CaptionLayout.scaleX(planeWidth: 960, frameWidth: 390) == 390.0 / 960.0)
    }

    @Test func captionLiftUsesTheFullVideoFrame() {
        let videoFrame = CGRect(x: 0, y: 20, width: 1920, height: 1080)
        // 安全領域の上下の余白は各 60pt。操作の列は安全領域の下端から 355pt。
        let controlsTop = videoFrame.maxY - 60 - 355
        #expect(CaptionLayout.liftAboveControls(
            normalizedBottom: 0.9, videoFrame: videoFrame, controlsTop: controlsTop
        ) == 323)
        #expect(CaptionLayout.liftAboveControls(
            normalizedBottom: 0.5, videoFrame: videoFrame, controlsTop: controlsTop
        ) == 0)
    }

    @Test func cellCountFollowsCodePoints() {
        // 区画の数は text のコードポイントの数
        #expect(CaptionLayout.cellCount(of: run) == 4)
        let joined = CaptionRun(
            x: 250, y: 450, w: 80, h: 60, fx: 2, fy: 12, size: 36, scaleX: 1,
            text: "か゚", joined: true, drcs: nil,
            fg: "#ffffffff", bg: "#00000080", stroke: nil, underline: nil, bold: nil, italic: nil, box: nil, flash: nil, ruby: nil
        )
        // joined の run は text 全体で 1 区画
        #expect(CaptionLayout.cellCount(of: joined) == 1)
    }

    @Test func cellPositions() {
        // 1 字ごとに幅 w の区画を x から右へ
        #expect(CaptionLayout.cell(of: run, index: 0) == CGRect(x: 250, y: 450, width: 40, height: 60))
        #expect(CaptionLayout.cell(of: run, index: 2) == CGRect(x: 330, y: 450, width: 40, height: 60))
        #expect(CaptionLayout.character(of: run, index: 2) == "で")
    }

    @Test func glyphFrame() {
        // 区画の左上から (fx, fy) ずらした所。高さ size、幅 size * scaleX
        let frame = CaptionLayout.glyphFrame(of: run, index: 0)
        #expect(frame == CGRect(x: 252, y: 462, width: 36, height: 36))

        let narrow = CaptionRun(
            x: 250, y: 450, w: 20, h: 60, fx: 2, fy: 12, size: 36, scaleX: 0.5,
            text: "ｱ", joined: nil, drcs: nil,
            fg: "#ffffffff", bg: "#00000080", stroke: nil, underline: nil, bold: nil, italic: nil, box: nil, flash: nil, ruby: nil
        )
        // 中くらい (MSZ) の全角は 0.5 に縮める
        #expect(CaptionLayout.glyphFrame(of: narrow, index: 0).width == 18)
    }

    @Test func baselineCentersInk() {
        // 「永」の墨の上下が字の枠の真ん中に来る基準線
        let ink = CaptionLayout.Ink(ascent: 0.8, descent: 0.2)
        let baseline = CaptionLayout.baselineOffset(ink: ink)
        // 墨の中心 = baseline - (ascent - descent)/2 が枠の中央 (0.5) に来る
        #expect(baseline - (ink.ascent - ink.descent) / 2 == 0.5)
    }

    @Test func spaceCharacters() {
        // U+0020・U+3000 などは字を描かない
        #expect(CaptionLayout.isSpace(" "))
        #expect(CaptionLayout.isSpace("　"))
        #expect(CaptionLayout.isSpace("\u{2003}"))
        #expect(!CaptionLayout.isSpace("字"))
    }

    @Test func flashPhase() {
        // 0.5 秒ずつ。絶対時計の位相
        #expect(!CaptionLayout.isDark(at: 0))
        #expect(CaptionLayout.isDark(at: 500))
        #expect(!CaptionLayout.isDark(at: 1000))
        #expect(CaptionLayout.isDark(at: 2500))
    }

    @Test func inkSpanCoversAllRuns() {
        let low = CaptionRun(
            x: 0, y: 400, w: 40, h: 60, fx: 0, fy: 0, size: 36, scaleX: 1,
            text: "下", joined: nil, drcs: nil,
            fg: "#ffffffff", bg: "#00000080", stroke: nil, underline: nil, bold: nil, italic: nil, box: nil, flash: nil, ruby: nil
        )
        let page = CaptionPage(v: 1, plane: [960, 540], duration: nil, runs: [run, low], drcs: nil)
        let span = CaptionLayout.inkSpan(page: page)
        #expect(span.top == 400.0 / 540.0)
        #expect(span.bottom == 510.0 / 540.0)
        // 字が無ければ [0, 0]
        #expect(CaptionLayout.inkSpan(page: CaptionPage(v: 1, plane: [960, 540], duration: nil, runs: [], drcs: nil)) == (0, 0))
    }

    @Test func colorsParse() throws {
        let white = try #require(CaptionLayout.rgba("#ffffffff"))
        #expect(white == (255, 255, 255, 255))
        #expect(CaptionLayout.rgba("#00000080")?.a == 128)
        #expect(CaptionLayout.isTransparent("#00000000"))
        #expect(!CaptionLayout.isTransparent("#00000080"))
        #expect(CaptionLayout.rgba("赤") == nil)
    }
}
