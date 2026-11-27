import Foundation
import Testing

@testable import Milu

struct DRCSTests {
    private func drcs(w: Int, h: Int, depth: Int, bits: Int, data: String) -> CaptionDrcs {
        CaptionDrcs(w: w, h: h, depth: depth, bits: bits, data: data, md5: nil)
    }

    @Test func bits1() throws {
        // 2x2 = 4 画素。0, 1, 1, 0 を上の桁から → 0b0110_0000 = 0x60
        let image = try #require(drcs(w: 2, h: 2, depth: 2, bits: 1, data: Data([0x60]).base64EncodedString()).grayscale())
        #expect(image.width == 2 && image.height == 2)
        #expect(image.samples == [0, 255, 255, 0])
    }

    @Test func bits2() throws {
        // 2x2 = 4 画素。0, 1, 2, 3 → 00 01 10 11 = 0x1b
        let image = try #require(drcs(w: 2, h: 2, depth: 4, bits: 2, data: Data([0x1b]).base64EncodedString()).grayscale())
        // v / (depth - 1): 1/3 → 85、2/3 → 170、3/3 → 255
        #expect(image.samples == [0, 85, 170, 255])
    }

    @Test func bits4() throws {
        // 2x1 = 2 画素。0, 15 → 0x0f
        let image = try #require(drcs(w: 2, h: 1, depth: 16, bits: 4, data: Data([0x0f]).base64EncodedString()).grayscale())
        #expect(image.samples == [0, 255])
    }

    @Test func bits4SpanningBytes() throws {
        // 3x1 = 3 画素。1, 2, 3 → 0001 0010 0011(0000) = 0x12 0x30
        let image = try #require(drcs(w: 3, h: 1, depth: 16, bits: 4, data: Data([0x12, 0x30]).base64EncodedString()).grayscale())
        #expect(image.samples == [17, 34, 51])
    }

    @Test func bits8() throws {
        let image = try #require(drcs(w: 2, h: 1, depth: 256, bits: 8, data: Data([0, 128]).base64EncodedString()).grayscale())
        #expect(image.samples == [0, 128])
    }

    @Test func rejectsUnknownBits() {
        #expect(drcs(w: 1, h: 1, depth: 2, bits: 3, data: "AA==").grayscale() == nil)
        #expect(drcs(w: 1, h: 1, depth: 2, bits: 0, data: "AA==").grayscale() == nil)
    }

    @Test func rejectsShortData() {
        // 2x2 で bits 8 なら 4 バイト要る
        #expect(drcs(w: 2, h: 2, depth: 256, bits: 8, data: Data([1, 2, 3]).base64EncodedString()).grayscale() == nil)
        #expect(drcs(w: 1, h: 1, depth: 2, bits: 1, data: "読めない").grayscale() == nil)
    }

    @Test func clampsLevelsAboveDepth() throws {
        // depth 2 なのに 2 が入っている (壊れたデータ)。1 (最大) に丸める
        let image = try #require(drcs(w: 1, h: 1, depth: 2, bits: 2, data: Data([0b1000_0000]).base64EncodedString()).grayscale())
        #expect(image.samples == [255])
    }
}
