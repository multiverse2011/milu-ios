import Foundation

/// デコードしたコマが表示の時刻に間に合ったかを見て、映すか・捨てるか・次のキーフレームへ飛ぶかを決める (純粋)。
///
/// 表示の層は遅れて届いたコマもそのまま映すので、デコードが遅れるとその分だけ映像が音より後ろになり、
/// 開き直すまで戻らない。denpa の Web (`components/player/unslip.ts`) と同じく、遅れが
/// `tolerance` (口の動きのずれが分かりはじめるところ) を超えたら直す。
nonisolated struct DecodeLag: Sendable {
    enum Action: Equatable, Sendable {
        /// 映す
        case show
        /// 表示の時刻を過ぎた。映さない
        case drop
        /// 遅れが続いている。デコードを次のキーフレームから始め直す
        case skipToKeyframe
    }

    /// これより遅れたコマを「遅れた」と数える (秒)
    static let tolerance = 0.1
    /// 遅れがこれだけ続いたら、デコーダが追いついていないと見て飛ぶ (秒)。一瞬の詰まりはデコーダが自分で取り戻す
    static let sustain = 1.0

    private var lateSince: Double?

    /// `pts`・`end` はコマの表示の始めと終わり、`now` は時計 (いずれも秒)
    mutating func frame(pts: Double, end: Double, now: Double) -> Action {
        if now - pts > Self.tolerance {
            let since = lateSince ?? now
            lateSince = since
            if now - since >= Self.sustain {
                lateSince = nil
                return .skipToKeyframe
            }
        } else {
            lateSince = nil
        }
        return end <= now ? .drop : .show
    }

    /// 飛んだ・止めた・開き直したとき。前の遅れを持ち越さない
    mutating func reset() {
        lateSince = nil
    }
}
