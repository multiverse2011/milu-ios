import Foundation
import Testing

@testable import Milu

struct GenreColorTests {
    @Test func tableColors() {
        #expect(GenreColor.color(0) == RGBA(0x4a, 0x90, 0xe2))
        #expect(GenreColor.color(1) == RGBA(0x2b, 0xb3, 0xa3))
        #expect(GenreColor.color(2) == RGBA(0x3a, 0xa8, 0xe8))
        #expect(GenreColor.color(3) == RGBA(0xd9, 0x57, 0x7a))
        #expect(GenreColor.color(4) == RGBA(0x9b, 0x6c, 0xd9))
        #expect(GenreColor.color(5) == RGBA(0xe0, 0xa0, 0x30))
        #expect(GenreColor.color(6) == RGBA(0xc4, 0x55, 0x3a))
        #expect(GenreColor.color(7) == RGBA(0xd6, 0x5f, 0xb8))
        #expect(GenreColor.color(8) == RGBA(0xd9, 0xa4, 0x41))
        #expect(GenreColor.color(10) == RGBA(0x6f, 0xbf, 0x4a))
    }

    @Test(arguments: [9, 11, 12, 13, 14, 15, 99] as [Int])
    func tableMisses(genre: Int) {
        // 表に無い値は面の色のまま、点は控えた字の色 (3.5)
        #expect(GenreColor.color(genre) == nil)
        #expect(GenreColor.cellBackground(genre) == GenreColor.surface)
    }

    @Test func nullGenre() {
        #expect(GenreColor.color(nil) == nil)
        #expect(GenreColor.cellBackground(nil) == RGBA(0x1c, 0x1c, 0x1e))
    }

    @Test func cellBackgroundMixesAt14Percent() {
        // ジャンル 0 (#4a90e2) を面 (#1c1c1e) に 14% 混ぜる
        #expect(GenreColor.cellBackground(0) == RGBA(0x22, 0x2c, 0x39))
        // 表に無い値は面の色のまま
        #expect(GenreColor.cellBackground(nil) == GenreColor.surface)
    }

    @Test func mixingRoundsToNearest() {
        #expect(RGBA(255, 255, 255).mixed(into: RGBA(0, 0, 0), ratio: 0.5) == RGBA(128, 128, 128))
        #expect(RGBA(0, 0, 0).mixed(into: RGBA(255, 255, 255), ratio: 0.5) == RGBA(128, 128, 128))
        #expect(RGBA(255, 0, 0).mixed(into: RGBA(0, 0, 0), ratio: 0) == RGBA(0, 0, 0))
        #expect(RGBA(255, 0, 0).mixed(into: RGBA(0, 0, 0), ratio: 1) == RGBA(255, 0, 0))
    }
}
