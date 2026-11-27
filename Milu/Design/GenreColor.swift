import Foundation

/// 色の単位。3.5 の色の表は暗い表示の 16 進。
struct RGBA: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    nonisolated init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 面の色に `ratio` で混ぜた色。番組表のマスの地 (3.5)
    nonisolated func mixed(into surface: RGBA, ratio: Double) -> RGBA {
        func mix(_ base: UInt8, _ top: UInt8) -> UInt8 {
            let v = Double(base) + (Double(top) - Double(base)) * ratio
            return UInt8(min(255, max(0, v.rounded())))
        }
        return RGBA(mix(surface.r, r), mix(surface.g, g), mix(surface.b, b))
    }
}

/// 番組表のジャンルの色 (3.5)。番組表のマスの地は `cellBackground`、頭の点は `color`。
enum GenreColor {
    /// 面 (#1c1c1e)
    nonisolated static let surface = RGBA(0x1c, 0x1c, 0x1e)

    nonisolated static let table: [Int: RGBA] = [
        0: RGBA(0x4a, 0x90, 0xe2),
        1: RGBA(0x2b, 0xb3, 0xa3),
        2: RGBA(0x3a, 0xa8, 0xe8),
        3: RGBA(0xd9, 0x57, 0x7a),
        4: RGBA(0x9b, 0x6c, 0xd9),
        5: RGBA(0xe0, 0xa0, 0x30),
        6: RGBA(0xc4, 0x55, 0x3a),
        7: RGBA(0xd6, 0x5f, 0xb8),
        8: RGBA(0xd9, 0xa4, 0x41),
        10: RGBA(0x6f, 0xbf, 0x4a),
    ]

    /// ジャンルの色。表に無い値 (9・11〜15) と `nil` では `nil` — マスは面の色のまま、点は控えた字の色にする (3.5)。
    nonisolated static func color(_ genre: Int?) -> RGBA? {
        genre.flatMap { table[$0] }
    }

    /// マスの地。ジャンルの色を面に 14% 混ぜたもの。表に無い値は面の色のまま。
    nonisolated static func cellBackground(_ genre: Int?) -> RGBA {
        color(genre)?.mixed(into: surface, ratio: 0.14) ?? surface
    }
}
