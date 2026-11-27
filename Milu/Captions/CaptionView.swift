import CoreText
import SwiftUI

/// 字幕を 1 枚描く (3.5.2)。字幕の面 (plane) を、映像の枠に合わせて縦横それぞれ伸ばす。
///
/// run ごとに描く順: 地の塗り → 縁取り (1.5) → 字 → 下線・囲み (box)。空白 (U+0020・U+3000 など)
/// は字を描かず地だけ塗る。外字 (`drcs`) は濃淡の画像を字の枠いっぱいに双線形で伸ばす。
/// 字は Denpa Font (`fontName` で受ける。D9)。
struct CaptionView: View {
    var page: CaptionPage
    /// 字幕の字のフォントの名前 (登録済みのもの。D9)
    var fontName: String = DenpaFont.postScriptName
    /// 点滅などで字を描かない run
    var isRunHidden: (CaptionRun) -> Bool = { _ in false }

    var body: some View {
        Canvas { context, size in
            CaptionRenderer.render(page: page, in: &context, size: size, fontName: fontName, isRunHidden: isRunHidden)
        }
    }
}

/// `CaptionView` の描き本体。時計や状態を持たない。
enum CaptionRenderer {
    /// 1 枚を描く。`size` は映像の枠 (pt)。
    static func render(page: CaptionPage, in context: inout GraphicsContext, size: CGSize, fontName: String, isRunHidden: (CaptionRun) -> Bool) {
        let sx = CaptionLayout.scaleX(planeWidth: page.planeWidth, frameWidth: size.width)
        let sy = CaptionLayout.scaleY(planeHeight: page.planeHeight, frameHeight: size.height)
        guard sx > 0, sy > 0, let font = makeFont(named: fontName) else { return }
        let ink = measureInk(font: font)
        for run in page.runs {
            drawRun(run, page: page, in: &context, sx: sx, sy: sy, font: font, ink: ink, hidden: isRunHidden(run))
        }
    }

    private static func makeFont(named name: String) -> CTFont? {
        CTFontCreateWithName(name as CFString, 1, nil)
    }

    /// 「永」の墨の上下 (字の大きさ 1 あたり)。libaribcaption と同じ基準線を置くため (api.md)
    private static func measureInk(font: CTFont) -> CaptionLayout.Ink {
        let attributed = NSAttributedString(string: "永", attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        return CaptionLayout.Ink(ascent: Double(bounds.maxY), descent: Double(-bounds.minY))
    }

    /// run を 1 つ描く。隠す (点滅の消えた位相) run は地と囲みだけ描く。
    private static func drawRun(_ run: CaptionRun, page: CaptionPage, in context: inout GraphicsContext, sx: Double, sy: Double, font: CTFont, ink: CaptionLayout.Ink, hidden: Bool) {
        let cells = CaptionLayout.cellCount(of: run)
        let baseline = CaptionLayout.baselineOffset(ink: ink)

        // 地の塗り (空白の字も塗る)
        for index in 0..<cells {
            let rect = CaptionLayout.cell(of: run, index: index)
            fill(&context, rect: rect, sx: sx, sy: sy, color: run.bg)
        }

        guard !hidden else {
            drawBox(run, cells: cells, in: &context, sx: sx, sy: sy)
            return
        }

        // 縁取り (1.5。字より先)
        if run.stroke != nil {
            for index in 0..<cells {
                strokeGlyph(run, index: index, in: &context, sx: sx, font: font, baseline: baseline)
            }
        }

        // 字
        for index in 0..<cells {
            drawGlyph(run, page: page, index: index, in: &context, sx: sx, sy: sy, font: font, baseline: baseline)
        }

        // 下線・囲み
        drawBox(run, cells: cells, in: &context, sx: sx, sy: sy)
        if run.underline == true {
            for index in 0..<cells {
                underline(run, index: index, in: &context, sx: sx, sy: sy, baseline: baseline)
            }
        }
    }

    // MARK: 区画

    /// 区画の長方形を枠の座標へ。画素の境目にそろえる (caption-draw.ts と同じ。隣の区画の境が半透明になるのを防ぐ)
    private static func rectInFrame(_ rect: CGRect, sx: Double, sy: Double) -> CGRect {
        let l = (rect.minX * sx).rounded()
        let t = (rect.minY * sy).rounded()
        let r = (rect.maxX * sx).rounded()
        let b = (rect.maxY * sy).rounded()
        return CGRect(x: l, y: t, width: max(r - l, 0), height: max(b - t, 0))
    }

    private static func fill(_ context: inout GraphicsContext, rect: CGRect, sx: Double, sy: Double, color hex: String) {
        guard !CaptionLayout.isTransparent(hex), let rgba = CaptionLayout.rgba(hex) else { return }
        let rect = rectInFrame(rect, sx: sx, sy: sy)
        guard rect.width > 0, rect.height > 0 else { return }
        context.fill(Path(rect), with: .color(color(rgba)))
    }

    /// 囲み (HLC)。区画の縁に字の色の線 (1 下・2 右・4 上・8 左の和。太さは面の 1 単位)
    private static func drawBox(_ run: CaptionRun, cells: Int, in context: inout GraphicsContext, sx: Double, sy: Double) {
        guard let mask = run.box, !CaptionLayout.isTransparent(run.fg), let rgba = CaptionLayout.rgba(run.fg) else { return }
        let thicknessX = max(1, Int(sx.rounded(.down)))
        let thicknessY = max(1, Int(sy.rounded(.down)))
        for index in 0..<cells {
            let rect = rectInFrame(CaptionLayout.cell(of: run, index: index), sx: sx, sy: sy)
            let pieces: [CGRect?] = [
                mask & 4 != 0 ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: CGFloat(thicknessY)) : nil,
                mask & 1 != 0 ? CGRect(x: rect.minX, y: rect.maxY - CGFloat(thicknessY), width: rect.width, height: CGFloat(thicknessY)) : nil,
                mask & 8 != 0 ? CGRect(x: rect.minX, y: rect.minY, width: CGFloat(thicknessX), height: rect.height) : nil,
                mask & 2 != 0 ? CGRect(x: rect.maxX - CGFloat(thicknessX), y: rect.minY, width: CGFloat(thicknessX), height: rect.height) : nil,
            ]
            for piece in pieces {
                guard let piece else { continue }
                context.fill(Path(piece), with: .color(color(rgba)))
            }
        }
    }

    private static func underline(_ run: CaptionRun, index: Int, in context: inout GraphicsContext, sx: Double, sy: Double, baseline: Double) {
        guard !CaptionLayout.isTransparent(run.fg), let rgba = CaptionLayout.rgba(run.fg) else { return }
        let cell = CaptionLayout.cell(of: run, index: index)
        let frame = CaptionLayout.glyphFrame(of: run, index: index)
        // 区画の幅で字の下に線 (caption-draw.ts と同じ位置・太さ)
        let y = (frame.minY + baseline * Double(run.size) + Double(run.size) * 0.135) * sy
        let thickness = max(1, Double(run.size) * sy * 0.05)
        let rect = CGRect(x: cell.minX * sx, y: y, width: cell.width * sx, height: thickness)
        context.fill(Path(rect), with: .color(color(rgba)))
    }

    // MARK: 字

    private static func typeset(run: CaptionRun, index: Int, font: CTFont) -> CTLine? {
        let text = CaptionLayout.character(of: run, index: index)
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        return CTLineCreateWithAttributedString(attributed)
    }

    /// 1 区画の字の輪郭。ペンは字の枠の左端、基準線は「永」の墨の上下が枠の真ん中に来る所。
    /// 横は字の枠の幅に合わせて縮める (api.md)。
    private static func glyphPaths(run: CaptionRun, index: Int, font: CTFont, baseline: Double) -> [Path] {
        guard let line = typeset(run: run, index: index, font: font) else { return [] }
        let frame = CaptionLayout.glyphFrame(of: run, index: index)
        let fontSize = Double(run.size)
        let glyphWidth = frame.width
        let baselineY = frame.minY + baseline * fontSize
        var paths: [Path] = []
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for glyphRun in runs {
            let count = CTRunGetGlyphCount(glyphRun)
            let glyphs = [CGGlyph](unsafeUninitializedCapacity: count) { buffer, initializedCount in
                CTRunGetGlyphs(glyphRun, CFRangeMake(0, count), buffer.baseAddress!)
                initializedCount = count
            }
            let positions = [CGPoint](unsafeUninitializedCapacity: count) { buffer, initializedCount in
                CTRunGetPositions(glyphRun, CFRangeMake(0, count), buffer.baseAddress!)
                initializedCount = count
            }
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CGAffineTransform(
                    a: glyphWidth, b: 0,
                    c: 0, d: -fontSize,
                    tx: frame.minX + Double(position.x) * glyphWidth,
                    ty: baselineY - Double(position.y) * fontSize
                )
                guard let cgPath = CTFontCreatePathForGlyph(font, glyph, &transform) else { continue }
                paths.append(Path(cgPath))
            }
        }
        return paths
    }

    private static func strokeGlyph(_ run: CaptionRun, index: Int, in context: inout GraphicsContext, sx: Double, font: CTFont, baseline: Double) {
        guard let strokeHex = run.stroke, !CaptionLayout.isTransparent(strokeHex), let strokeRGBA = CaptionLayout.rgba(strokeHex) else { return }
        // 太さ 1.5 の外側へ。中心を輪郭に置くので 2 倍にする
        let style = StrokeStyle(lineWidth: 2 * CaptionLayout.strokeWidth * sx, lineJoin: .round)
        for path in glyphPaths(run: run, index: index, font: font, baseline: baseline) {
            context.stroke(path, with: .color(color(strokeRGBA)), style: style)
        }
    }

    private static func drawGlyph(_ run: CaptionRun, page: CaptionPage, index: Int, in context: inout GraphicsContext, sx: Double, sy: Double, font: CTFont, baseline: Double) {
        if run.drcs != nil {
            drawDrcs(run: run, page: page, index: index, in: &context, sx: sx, sy: sy)
            return
        }
        // 空白は字を描かない (地は塗ってある)
        if let scalar = CaptionLayout.character(of: run, index: index).unicodeScalars.first, CaptionLayout.isSpace(scalar) {
            return
        }
        guard !CaptionLayout.isTransparent(run.fg), let rgba = CaptionLayout.rgba(run.fg) else { return }
        for path in glyphPaths(run: run, index: index, font: font, baseline: baseline) {
            context.fill(path, with: .color(color(rgba)))
        }
    }

    // MARK: 外字

    /// 置き換えられなかった外字。`text` は「〓」で、`drcs` の画像を字の枠いっぱいに `fg` で描く。
    /// 濃淡は `fg` の不透明度に掛けて、双線形で伸ばす (api.md)。`drcs` が無ければ何も描かない。
    private static func drawDrcs(run: CaptionRun, page: CaptionPage, index: Int, in context: inout GraphicsContext, sx: Double, sy: Double) {
        guard let key = run.drcs, let drcs = page.drcs?[key], let gray = drcs.grayscale() else { return }
        let frame = rectInFrame(CaptionLayout.glyphFrame(of: run, index: index), sx: sx, sy: sy)
        // 縁取りは 4 方へずらして描く (caption-draw.ts と同じ)
        if let strokeHex = run.stroke, !CaptionLayout.isTransparent(strokeHex),
           let edge = tintedImage(drcs, samples: gray.samples, color: strokeHex) {
            let dx = CaptionLayout.strokeWidth * sx
            let dy = CaptionLayout.strokeWidth * sy
            for offset in [CGSize(width: -dx, height: 0), CGSize(width: dx, height: 0), CGSize(width: 0, height: -dy), CGSize(width: 0, height: dy)] {
                context.draw(edge, in: frame.offsetBy(dx: offset.width, dy: offset.height))
            }
        }
        guard let image = tintedImage(drcs, samples: gray.samples, color: run.fg) else { return }
        context.draw(image, in: frame)
    }

    /// 濃淡の画像を、その色で不透明度に濃さを掛けた画像にする。
    private static func tintedImage(_ drcs: CaptionDrcs, samples: [UInt8], color hex: String) -> Image? {
        guard let rgba = CaptionLayout.rgba(hex) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 4)
        for sample in samples {
            let alpha = Int(sample) * Int(rgba.a) / 255
            bytes.append(UInt8(Int(rgba.r) * alpha / 255))
            bytes.append(UInt8(Int(rgba.g) * alpha / 255))
            bytes.append(UInt8(Int(rgba.b) * alpha / 255))
            bytes.append(UInt8(alpha))
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let image = CGImage(
            width: drcs.w,
            height: drcs.h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: drcs.w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
        guard let image else { return nil }
        return Image(decorative: image, scale: 1)
    }

    // MARK: 色

    private static func color(_ rgba: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Color {
        Color(
            .sRGB,
            red: Double(rgba.r) / 255,
            green: Double(rgba.g) / 255,
            blue: Double(rgba.b) / 255,
            opacity: Double(rgba.a) / 255
        )
    }
}
