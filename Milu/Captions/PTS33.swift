import Foundation

/// 放送の PTS の比べ方 (4.4)。33 ビットで一周するので、比べるときは近いほうへ伸ばす。
enum PTS33 {
    nonisolated static let mask: UInt64 = (1 << 33) - 1
    nonisolated static let cycle: UInt64 = 1 << 33

    /// a − b を、一周を考慮して近いほうへ取る。結果の絶対値は `cycle / 2` 以下。
    nonisolated static func difference(_ a: UInt64, _ b: UInt64) -> Int64 {
        let am = a & mask
        let bm = b & mask
        let forward = am >= bm ? am - bm : am + cycle - bm
        if forward <= cycle / 2 { return Int64(forward) }
        return Int64(forward) - Int64(cycle)
    }

    /// `value` を `reference` に近い周期へ伸ばす (≡ value mod 2^33)。
    nonisolated static func extended(_ value: UInt64, near reference: UInt64) -> Int64 {
        Int64(reference) + difference(value, reference)
    }
}
