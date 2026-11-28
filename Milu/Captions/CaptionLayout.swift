import CoreGraphics
import Foundation

/// 字幕の面 (plane) から映像の枠への写し方と、run ごとの区画の置き方 (api.md「字幕の文字の配置」)。
/// 純粋な関数だけを置く。座標は面の左上を原点として y が下向き。時刻はミリ秒。
nonisolated enum CaptionLayout {
    /// 縁取りの太さ (面の単位)。字の輪郭の外側へ (api.md)
    static let strokeWidth = 1.5
    /// 点滅の間 (ms)。出す・消すの交互
    static let flashIntervalMs = 500.0

    /// 「永」の墨の上下 (字の大きさ 1 あたり)。基準線を決めるのに使う
    struct Ink: Equatable, Sendable {
        /// 基準線から墨の上端まで
        var ascent: Double
        /// 基準線から墨の下端まで
        var descent: Double

        nonisolated init(ascent: Double, descent: Double) {
            self.ascent = ascent
            self.descent = descent
        }
    }

    /// 面の座標を映像の枠の座標に伸ばす倍率。縦横それぞれ (3.5.2)
    nonisolated static func scaleX(planeWidth: Int, frameWidth: Double) -> Double {
        planeWidth > 0 ? frameWidth / Double(planeWidth) : 1
    }

    nonisolated static func scaleY(planeHeight: Int, frameHeight: Double) -> Double {
        planeHeight > 0 ? frameHeight / Double(planeHeight) : 1
    }

    /// run の区画の数。`text` のコードポイントの数。`joined` の run は全体で 1 つ (api.md)
    nonisolated static func cellCount(of run: CaptionRun) -> Int {
        run.joined == true ? 1 : run.text.unicodeScalars.count
    }

    /// run の i 番目の区画 (面の座標)。joined は i を 0 だけ受ける
    nonisolated static func cell(of run: CaptionRun, index i: Int) -> CGRect {
        CGRect(x: Double(run.x + i * run.w), y: Double(run.y), width: Double(run.w), height: Double(run.h))
    }

    /// 区画の中の字の枠 (面の座標)。区画の左上から (fx, fy) ずらした所。高さ `size`、幅 `size * scaleX`
    nonisolated static func glyphFrame(of run: CaptionRun, index i: Int) -> CGRect {
        let origin = cell(of: run, index: i).origin
        return CGRect(
            x: origin.x + Double(run.fx),
            y: origin.y + Double(run.fy),
            width: Double(run.size) * run.scaleX,
            height: Double(run.size)
        )
    }

    /// 字の枠の i 番目に入る字。joined は text 全体
    nonisolated static func character(of run: CaptionRun, index i: Int) -> String {
        if run.joined == true { return run.text }
        return String(run.text.unicodeScalars.dropFirst(i).first!)
    }

    /// 「永」の墨の上下が字の枠の真ん中に来る基準線 (字の枠の上からの距離)
    nonisolated static func baselineOffset(ink: Ink) -> Double {
        let size = 1.0
        return (size - (ink.ascent + ink.descent) * size) / 2 + ink.ascent * size
    }

    /// 空白として字を描かない (背景だけ塗る) 字。libaribcaption の IsSpaceCharacter と同じ (api.md)
    nonisolated static func isSpace(_ codepoint: Unicode.Scalar) -> Bool {
        switch codepoint.value {
        case 0x09, 0x20, 0xa0, 0x1680, 0x3000, 0x202f, 0x205f:
            return true
        case 0x2000...0x200a:
            return true
        default:
            return false
        }
    }

    /// 点滅の位相。絶対時計で 0.5 秒ずつ出す・消す (caption-draw.ts `drawPage` の `dark` と同じ)
    nonisolated static func isDark(at timeMs: Double) -> Bool {
        Int(timeMs / flashIntervalMs) % 2 == 1
    }

    /// 字の載っている縦の範囲 `[上, 下]` (面の高さに対する割合 0〜1)。背景の区画まで含める。
    /// 操作の層を出している間に字幕を持ち上げる量を決めるのに使う (3.5.2)。字が無ければ `[0, 0]`
    nonisolated static func inkSpan(page: CaptionPage) -> (top: Double, bottom: Double) {
        let height = Double(page.planeHeight)
        guard !page.runs.isEmpty, height > 0 else { return (0, 0) }
        var top = Double.greatestFiniteMagnitude
        var bottom = 0.0
        for run in page.runs {
            top = min(top, Double(run.y))
            bottom = max(bottom, Double(run.y + run.h))
        }
        return (max(0, top / height), min(1, bottom / height))
    }

    /// 共通の座標系で、字幕の下端と操作の列の上端の間を 16pt 空ける。
    nonisolated static func liftAboveControls(
        normalizedBottom: CGFloat, videoFrame: CGRect, controlsTop: CGFloat
    ) -> CGFloat {
        let captionBottom = videoFrame.minY + normalizedBottom * videoFrame.height
        return max(0, captionBottom - controlsTop + 16)
    }

    /// `#rrggbbaa` を読む。字の色・背景の色に使う
    nonisolated static func rgba(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard hex.hasPrefix("#"), hex.count == 9, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff))
    }

    /// 不透明度 0 の色 (塗らない)
    nonisolated static func isTransparent(_ hex: String) -> Bool {
        rgba(hex)?.a == 0
    }
}
