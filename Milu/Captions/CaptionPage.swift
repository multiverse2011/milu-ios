import Foundation

/// 字幕の文字の配置 (api.md「字幕の文字の配置」の `page`)。`v` が 1 でなければ描かない (3.5.2)。
struct CaptionPage: @nonisolated Decodable, Equatable, Sendable {
    /// 形式のバージョン
    var v: Int
    /// 字幕の面の大きさ `[幅, 高さ]`
    var plane: [Int]
    /// 出しておく長さ (ms)。`null` なら次の 1 枚まで
    var duration: Int?
    /// 字の並び。描く順
    var runs: [CaptionRun]
    /// 置き換えられなかった外字の画像。`CaptionRun.drcs` で引く
    var drcs: [String: CaptionDrcs]?

    nonisolated var planeWidth: Int { plane.first ?? 0 }
    nonisolated var planeHeight: Int { plane.count > 1 ? plane[1] : 0 }
    /// v1 だけ描く
    nonisolated var isSupported: Bool { v == 1 }
}

/// 同じ見た目で横に並ぶ字。`text` の 1 字 (コードポイント) ごとに、幅 `w` の区画を `x` から右へ 1 つずつ使う。
struct CaptionRun: @nonisolated Decodable, Equatable, Sendable {
    /// 1 字目の区画の左上
    var x: Int
    var y: Int
    /// 区画 1 つの幅・高さ。背景 (`bg`) はこの広さを塗る
    var w: Int
    var h: Int
    /// 区画の左上から、字の枠の左上まで
    var fx: Int
    var fy: Int
    /// 字の大きさ (em)。字の枠の高さ
    var size: Int
    /// 横の縮め方。字の枠の幅は `size * scaleX`
    var scaleX: Double
    var text: String
    /// `text` 全体で 1 つの区画 (2 つのコードポイントで 1 字のもの)
    var joined: Bool?
    /// 置き換えられなかった外字。`text` は「〓」で、この画像を字の枠いっぱいに描く
    var drcs: String?
    /// 字の色 `#rrggbbaa`
    var fg: String
    /// 背景の色 (区画)
    var bg: String
    /// 縁取りの色。無ければ縁取らない
    var stroke: String?
    var underline: Bool?
    var bold: Bool?
    var italic: Bool?
    /// 囲み。1 下・2 右・4 上・8 左の和
    var box: Int?
    var flash: Bool?
    var ruby: Bool?
}

/// 外字の画像。`data` は base64 で、左上から 1 画素 `bits` ビットずつ (上の桁から) 詰めたもの。
struct CaptionDrcs: @nonisolated Decodable, Equatable, Sendable {
    var w: Int
    var h: Int
    /// 階調の数。値 v の濃さは v / (depth - 1)
    var depth: Int
    var bits: Int
    var data: String
    /// 放送の元の画像の MD5。描くのには使わない
    var md5: String?

    nonisolated init(w: Int, h: Int, depth: Int, bits: Int, data: String, md5: String? = nil) {
        self.w = w
        self.h = h
        self.depth = depth
        self.bits = bits
        self.data = data
        self.md5 = md5
    }
}

extension CaptionDrcs {
    /// 1 画素 1 バイトの濃淡 (0...255、255 がいちばん濃い) に読む。`bits` は 1・2・4・8。
    /// base64 が読めない・足りなければ `nil`。
    nonisolated func grayscale() -> (width: Int, height: Int, samples: [UInt8])? {
        guard [1, 2, 4, 8].contains(bits), depth >= 2, w > 0, h > 0,
              let bytes = Data(base64Encoded: data) else {
            return nil
        }
        let count = w * h
        guard bytes.count * 8 >= count * bits else { return nil }

        var samples = [UInt8]()
        samples.reserveCapacity(count)
        var bitIndex = 0
        for _ in 0..<count {
            let shift = 8 - (bitIndex & 7) - bits
            let value = (Int(bytes[bitIndex >> 3]) >> shift) & ((1 << bits) - 1)
            bitIndex += bits
            let level = min(1, Double(value) / Double(depth - 1))
            samples.append(UInt8((level * 255).rounded()))
        }
        return (w, h, samples)
    }
}
