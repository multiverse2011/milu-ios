import Foundation
import Testing
@testable import Milu

@Suite struct TVReadingTests {
    /// 標準の大きさでの 1 行の上限。境界のテストはこの値から作る
    private static let chars = TVReading.limits(scale: 1).chars

    @Test func 短い本文はひとつの塊のまま() {
        #expect(TVReading.blocks("ひとつだけの段落。") == ["ひとつだけの段落。"])
    }

    @Test func 空行で段落に分ける() {
        #expect(TVReading.blocks("前の段落。\n\n後の段落。") == ["前の段落。", "後の段落。"])
    }

    @Test func 空の本文は何も返さない() {
        #expect(TVReading.blocks("").isEmpty)
        #expect(TVReading.blocks("\n\n\n").isEmpty)
    }

    @Test func 行数の上限で分ける() {
        let text = (1...30).map { "行\($0)" }.joined(separator: "\n")
        let blocks = TVReading.blocks(text)
        #expect(blocks.count == 3)
        #expect(blocks[0].components(separatedBy: "\n").count == TVReading.maxLines)
        #expect(blocks[2].components(separatedBy: "\n").count == 30 - TVReading.maxLines * 2)
    }

    @Test func 改行の無い長い文は文の切れ目で分ける() {
        let text = String(repeating: "あ。", count: 300)
        let blocks = TVReading.blocks(text)
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.count <= TVReading.maxChars })
        #expect(blocks.joined() == text)
    }

    @Test func CRLFの改行も段落に分ける() {
        #expect(TVReading.blocks("前の段落。\r\n\r\n後の段落。") == ["前の段落。", "後の段落。"])
    }

    @Test func 数字の中のピリオドでは切らない() {
        let text = String(repeating: "あ", count: Self.chars - 10) + "1.1" + String(repeating: "い", count: 20)
        #expect(TVReading.blocks(text)[0].count == Self.chars)
    }

    @Test func 空白の後ろのピリオドは文末として切る() {
        let text = String(repeating: "あ", count: Self.chars - 10) + "Mr. " + String(repeating: "い", count: 20)
        #expect(TVReading.blocks(text)[0].hasSuffix("Mr."))
    }

    @Test func 文末が無ければ最後の空白で切る() {
        let text = String(repeating: "a", count: Self.chars - 10) + " " + String(repeating: "b", count: 20)
        #expect(TVReading.blocks(text)[0].count == Self.chars - 10)
    }

    @Test func 上限ちょうどの長文は分けない() {
        let exact = String(repeating: "あ", count: TVReading.maxChars)
        #expect(TVReading.blocks(exact) == [exact])
        #expect(TVReading.blocks(exact + "い").count == 2)
    }

    @Test func 大きな字では塊を小さくする() {
        let base = TVReading.limits(scale: 1)
        #expect(base.lines == TVReading.maxLines)
        #expect(base.chars == TVReading.maxChars)
        let double = TVReading.limits(scale: 2)
        #expect(double.lines == 6)
        #expect(double.chars == 200)
        let middle = TVReading.limits(scale: 1.5)
        #expect(middle.lines == 8)
        #expect(middle.chars == 266)
        // 拡大しない側 (1 より小さい) は変えない
        #expect(TVReading.limits(scale: 0.8).lines == TVReading.maxLines)
    }

    @Test func 大きな字では塊の上限で実際に分ける() {
        let limits = TVReading.limits(scale: 2)
        let text = (1...40).map { _ in String(repeating: "あ", count: 20) }.joined(separator: "\n")
        let blocks = TVReading.blocks(text, scale: 2)
        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.components(separatedBy: "\n").count <= limits.lines })
        #expect(blocks.allSatisfy { $0.count <= limits.chars })
    }

    @Test func 案内は本文が画面外にあるときだけ出す() {
        // 収まる
        #expect(!TVReading.hasMore(visibleMaxY: 1000, contentHeight: 1000, bottomPadding: 0))
        // 本文の終わりちょうどまで見えている
        #expect(!TVReading.hasMore(visibleMaxY: 880, contentHeight: 1000, bottomPadding: 120))
        // 下に足した余白だけが画面外
        #expect(!TVReading.hasMore(visibleMaxY: 900, contentHeight: 1000, bottomPadding: 120))
        // 本文が 1pt はみ出す
        #expect(TVReading.hasMore(visibleMaxY: 878, contentHeight: 1000, bottomPadding: 120))
        #expect(TVReading.hasMore(visibleMaxY: 999, contentHeight: 1000, bottomPadding: 0))
        // 中身が表示域より小さい
        #expect(!TVReading.hasMore(visibleMaxY: 500, contentHeight: 300, bottomPadding: 0))
    }

    @Test func ライセンスの下余白だけなら続きの案内を出さない() {
        #expect(!TVReading.hasMore(visibleMaxY: 960, contentHeight: 1000, bottomPadding: 40))
        #expect(TVReading.hasMore(visibleMaxY: 959, contentHeight: 1000, bottomPadding: 40))
    }

    @Test func OFLの全文が上限の内側の塊になる() throws {
        let url = try #require(Bundle.main.url(forResource: "OFL", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let blocks = TVReading.blocks(text)
        #expect(!blocks.isEmpty)
        #expect(blocks.allSatisfy { $0.components(separatedBy: "\n").count <= TVReading.maxLines })
        #expect(blocks.allSatisfy { $0.count <= TVReading.maxChars })
        #expect(blocks.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
    }
}
