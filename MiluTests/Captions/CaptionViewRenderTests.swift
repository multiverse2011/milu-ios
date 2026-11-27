import CoreText
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Milu

/// CaptionView の描きを ImageRenderer で PNG に書き出す。画像は作業ツリーの外に置き、目視で確かめる。
/// Denpa Font (danything/denpa-font v3.7) は /tmp に置いたものを CTFontManager に登録して使う (リポジトリには入れない)。
struct CaptionViewRenderTests {
    private static let outputDirectory = "/tmp/caption-check"
    private func ensureFont() throws {
        // UIAppFonts で登録済み。テストのホストでも家族名で引けることを確かめる
        let font = CTFontCreateWithName(DenpaFont.postScriptName as CFString, 36, nil)
        #expect(CTFontCopyFamilyName(font) as String == "Denpa Font", "Denpa Font が見つからない")
    }

    private func write(_ view: some View, name: String, size: CGSize) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let png = renderer.uiImage?.pngData() else {
            Issue.record("PNG の生成に失敗: \(name)")
            return
        }
        try FileManager.default.createDirectory(atPath: Self.outputDirectory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: "\(Self.outputDirectory)/\(name).png")
        try png.write(to: url)
        print("wrote \(url.path) (\(png.count) bytes)")
    }

    private func run(
        x: Int, y: Int, w: Int, h: Int, fx: Int = 2, fy: Int = 12, size: Int, scaleX: Double = 1,
        text: String, joined: Bool? = nil, drcs: String? = nil,
        fg: String = "#ffffffff", bg: String = "#00000080", stroke: String? = nil,
        underline: Bool? = nil, box: Int? = nil, ruby: Bool? = nil
    ) -> CaptionRun {
        CaptionRun(
            x: x, y: y, w: w, h: h, fx: fx, fy: fy, size: size, scaleX: scaleX,
            text: text, joined: joined, drcs: drcs, fg: fg, bg: bg, stroke: stroke,
            underline: underline, bold: nil, italic: nil, box: box, flash: nil, ruby: ruby
        )
    }

    /// 72x72・bits 4・depth 16 の外字。円環の形で、引き伸ばしと濃淡が分かるようにする。
    private func circleDrcs() -> CaptionDrcs {
        let width = 72, height = 72, bits = 4, depth = 16
        var bytes = [UInt8](repeating: 0, count: (width * height * bits + 7) / 8)
        var bitIndex = 0
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x - width / 2), dy = Double(y - height / 2)
                let distance = (dx * dx + dy * dy).squareRoot()
                let value: UInt8
                if distance < 22 {
                    value = 0
                } else if distance < 30 {
                    value = UInt8(min(depth - 1, Int((distance - 22) / 8 * Double(depth - 1)) + 4))
                } else {
                    value = 0
                }
                let shift = 8 - (bitIndex & 7) - bits
                bytes[bitIndex >> 3] |= value << UInt8(shift)
                bitIndex += bits
            }
        }
        return CaptionDrcs(
            w: width, h: height, depth: depth, bits: bits,
            data: Data(bytes).base64EncodedString(), md5: nil
        )
    }

    @Test func renderApiExample() throws {
        try ensureFont()
        let drcs = circleDrcs()
        let page = CaptionPage(
            v: 1, plane: [960, 540], duration: 3000,
            runs: [
                run(x: 250, y: 450, w: 40, h: 60, size: 36, text: "字幕です"),
                run(x: 470, y: 450, w: 40, h: 60, size: 36, text: "〓", drcs: "65569", stroke: "#000000ff"),
            ],
            drcs: ["65569": drcs]
        )
        try write(CaptionView(page: page), name: "01-api-example", size: CGSize(width: 960, height: 540))
    }

    @Test func renderDecorations() throws {
        try ensureFont()
        let page = CaptionPage(
            v: 1, plane: [960, 540], duration: nil,
            runs: [
                // 縁取り + 中くらい (scaleX 0.5) の全角
                run(x: 60, y: 60, w: 40, h: 60, size: 36, scaleX: 0.5, text: "縁取りの字", stroke: "#ff0000ff"),
                // 下線 + 囲み (四辺)
                run(x: 60, y: 200, w: 40, h: 60, size: 36, text: "下線と囲み", bg: "#0000ff80", underline: true, box: 15),
                // 空白は字を描かず地だけ塗る (U+0020 と U+3000)
                run(x: 60, y: 340, w: 60, h: 60, size: 36, text: "空 白　地", bg: "#00800080"),
                // 背景の不透明度 0 (塗らない)
                run(x: 60, y: 460, w: 40, h: 60, size: 36, text: "背景なし", bg: "#00000000"),
            ],
            drcs: nil
        )
        try write(CaptionView(page: page), name: "02-decorations", size: CGSize(width: 960, height: 540))
    }

    @Test func renderRubyAndJoined() throws {
        try ensureFont()
        let page = CaptionPage(
            v: 1, plane: [960, 540], duration: nil,
            runs: [
                run(x: 100, y: 120, w: 40, h: 60, size: 36, text: "漢字の読み", ruby: true),
                // joined: 2 コードポイントで 1 字 (フォントが 1 字に組む)
                run(x: 100, y: 300, w: 80, h: 60, size: 36, text: "か゚", joined: true),
                // 同じ text を joined でない run と並べて、区画の違いを見る
                run(x: 300, y: 300, w: 40, h: 60, size: 36, text: "か゚"),
            ],
            drcs: nil
        )
        try write(CaptionView(page: page), name: "03-ruby-joined", size: CGSize(width: 960, height: 540))
    }

    @Test func renderFlashDarkShowsBackgroundOnly() throws {
        try ensureFont()
        let page = CaptionPage(
            v: 1, plane: [960, 540], duration: nil,
            runs: [
                run(x: 100, y: 120, w: 40, h: 60, size: 36, text: "点滅の消えた位相", underline: true, box: 15),
            ],
            drcs: nil
        )
        // 点滅で消えている run は地と囲みだけ描く
        try write(CaptionView(page: page, isRunHidden: { _ in true }), name: "04-flash-dark", size: CGSize(width: 960, height: 540))
    }
}
