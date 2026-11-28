import Foundation

/// 同じ押下が 2 つの経路 (決定・再生/一時停止ボタンと Now Playing) から届いたときに、
/// 間をあけずに来た 2 度目を捨てる。時刻は単調な時計で測るので、端末の時計が戻っても押下を捨て続けない
struct PressGuard {
    /// 同じ押下とみなす間隔
    private static let window: UInt64 = 400_000_000
    /// 押下の時刻。テストから差し替える
    var now: () -> DispatchTime = { .now() }
    private var last: DispatchTime?

    /// 押下を控える。窓の外なら控えて true、2 度目なら false。
    /// 時計が戻った (単調でない) ときは窓の外として扱い、押下は捨てない
    mutating func claim() -> Bool {
        let at = now()
        if let last,
           at.uptimeNanoseconds >= last.uptimeNanoseconds,
           at.uptimeNanoseconds - last.uptimeNanoseconds < Self.window {
            return false
        }
        self.last = at
        return true
    }

    /// 控えを捨てる (選局し直しは新しい押下として扱う)
    mutating func reset() {
        last = nil
    }
}
