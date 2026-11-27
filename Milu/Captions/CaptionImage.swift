import SwiftUI

/// 字幕の 1 枚を UIImage にする。CaptionView の Canvas を ImageRenderer で描く。
/// 映像は UIView (AVSampleBufferDisplayLayer) なので、Canvas をそのまま重ねず、
/// VideoSurface に画像として渡して映像のレイヤのすぐ上に置く。
@MainActor
enum CaptionImage {
    static func render(page: CaptionPage, hidden: @escaping (CaptionRun) -> Bool) -> UIImage? {
        let size = CGSize(width: max(1, page.planeWidth), height: max(1, page.planeHeight))
        let renderer = ImageRenderer(
            content: CaptionView(
                page: page,
                fontName: DenpaFont.postScriptName,
                isRunHidden: hidden
            )
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        return renderer.uiImage
    }
}
