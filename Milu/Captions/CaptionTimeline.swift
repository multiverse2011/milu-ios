import Foundation

/// いつ何を出すかの決まり (3.5.2・api.md「録画の字幕」)。純粋な型。時刻は呼ぶ側の時計 (ミリ秒)。
///
/// - 新しい 1 枚が来たら前の 1 枚を丸ごと置き換える
/// - `runs` が空なら消す
/// - `duration` (ms) があればその時間がたったら次を待たずに消す。`null` なら次の 1 枚まで出す
/// - `v` が 1 でなければ描かない (来た 1 枚を捨てて、いま出しているものはそのままにする)
struct CaptionTimeline: Equatable, Sendable {
    private(set) var current: CaptionPage?
    /// いまの 1 枚を出し始めた時刻 (ミリ秒)。消す指示と空の runs の 1 枚では nil
    private var shownAt: Double?

    nonisolated init() {}

    /// 出す 1 枚を替える。`nil` と `runs` が空の 1 枚は消す。`v` が 1 でない 1 枚は捨てる (いまのものは替わらない)。
    mutating func show(_ page: CaptionPage?, at timeMs: Double) {
        guard let page else {
            current = nil
            shownAt = nil
            return
        }
        guard page.v == 1 else { return }
        guard !page.runs.isEmpty else {
            current = nil
            shownAt = nil
            return
        }
        current = page
        shownAt = timeMs
    }

    /// 時刻 `timeMs` に出す 1 枚。`duration` が過ぎていれば消える (`nil`)
    func page(at timeMs: Double) -> CaptionPage? {
        guard let current, let shownAt else { return nil }
        if let duration = current.duration, timeMs - shownAt >= Double(duration) {
            return nil
        }
        return current
    }

    /// `flash` の run が、この時刻では消えているか (0.5 秒ずつの点滅)
    func isHidden(_ run: CaptionRun, at timeMs: Double) -> Bool {
        run.flash == true && CaptionLayout.isDark(at: timeMs)
    }
}
