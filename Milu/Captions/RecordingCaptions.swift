import Foundation

/// `GET api/recordings/<id>/captions.json` の応答 (3.5.2)。`pages` は第 1 言語だけを使う。
struct RecordingCaptions: @nonisolated Decodable, Equatable, Sendable {
    var v: Int
    var pages: [RecordingCaptionPage]
}

/// 物差しの上の 1 枚。`at` は `playback` の物差しの秒。
struct RecordingCaptionPage: @nonisolated Decodable, Equatable, Sendable {
    var at: Double
    var page: CaptionPage
}

extension CaptionTimeline {
    /// 録画の字幕を、位置 `position` のところまで反映する。シークのたびに作り直す。
    @MainActor static func rebuilt(from pages: [RecordingCaptionPage], position: Double) -> CaptionTimeline {
        var timeline = CaptionTimeline()
        for entry in pages where entry.at <= position + 0.001 {
            timeline.show(entry.page, at: entry.at * 1000)
        }
        return timeline
    }
}
