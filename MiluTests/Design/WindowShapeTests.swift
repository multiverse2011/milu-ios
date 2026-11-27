import CoreGraphics
import Testing

@testable import Milu

struct WindowShapeTests {
    /// 横長の iPad はカード (画面案 iPad-Search は 1180×820)
    @Test func wideOnLandscapePad() {
        #expect(WindowShape.isWide(
            isPad: true,
            isRegularWidth: true,
            window: CGSize(width: 1_180, height: 820)
        ))
    }

    /// 縦の iPad は行。検索欄にフォーカスしてキーボードで表示領域が 834×794 に
    /// 縮んでも、ここに渡すのはウィンドウの大きさなので横長にならない (issue #65)。
    /// キーボードで縮んだ表示領域を渡せば横長と判定されてしまうので、
    /// 呼び出し側がウィンドウの大きさを渡すことは View の形で担保する。
    /// このテストが守るのは述語と、iPhone・コンパクト幅のガードまで
    @Test func rowOnPortraitPad() {
        #expect(!WindowShape.isWide(
            isPad: true,
            isRegularWidth: true,
            window: CGSize(width: 834, height: 1_210)
        ))
    }

    /// iPhone は横向きでも行のまま
    @Test func rowOnPhone() {
        #expect(!WindowShape.isWide(
            isPad: false,
            isRegularWidth: true,
            window: CGSize(width: 1_210, height: 834)
        ))
    }

    /// コンパクト幅 (縦長の Split View など) は行
    @Test func rowOnCompactWidth() {
        #expect(!WindowShape.isWide(
            isPad: true,
            isRegularWidth: false,
            window: CGSize(width: 1_210, height: 834)
        ))
    }
}
