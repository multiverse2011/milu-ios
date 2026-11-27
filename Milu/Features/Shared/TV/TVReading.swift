import SwiftUI

/// tvOS の本文。フォーカスできない `Text` は、そのままでは下キーで送れない。
/// 画面に収まる長さの塊に分け、塊ごとにフォーカスできるようにして上下で読ませる。
struct TVReadingText: View {
    let text: String
    var font: Font = .body
    var lineSpacing: CGFloat = 12
    /// `DenpaFont` は端末の字の設定で拡大する (`Design/Font.swift`)。拡大する画面では塊を小さくする。
    /// `system` の固定の字の画面は拡大しないので false のまま
    var scalesWithTextSize = false

    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        let scale = scalesWithTextSize ? textScale : 1
        VStack(alignment: .leading, spacing: lineSpacing + 10) {
            ForEach(Array(TVReading.blocks(text, scale: scale).enumerated()), id: \.offset) { _, block in
                Text(block)
                    .font(font)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
                    .focusEffectDisabled()
            }
        }
    }
}

/// 本文を焦点の塊に分ける決まり。1 つの塊が画面に収まるよう、行数と文字数の両方で区切る。
/// 改行の無い長い説明は、文の切れ目 (無ければ空白) で分ける。
nonisolated enum TVReading {
    /// 塊にする行数の上限 (標準の大きさの 30 級の字で 12 行なら、1080p の画面に収まる)
    static let maxLines = 12
    /// 1 行の文字数の上限
    static let maxChars = 400

    /// 字の拡大率に合わせた上限。拡大するほど 1 つの塊を小さくする
    static func limits(scale: CGFloat) -> (lines: Int, chars: Int) {
        let scale = max(scale, 1)
        return (max(1, Int(CGFloat(maxLines) / scale)), max(1, Int(CGFloat(maxChars) / scale)))
    }

    static func blocks(_ text: String, scale: CGFloat = 1) -> [String] {
        let limits = limits(scale: scale)
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .flatMap { paragraph in
                grouped(
                    paragraph.components(separatedBy: "\n").flatMap { sentences($0, maxChars: limits.chars) },
                    maxLines: limits.lines,
                    maxChars: limits.chars
                )
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 画面の外に本文の続きがあるか。下端に足した余白だけが画面外のときは続きと見なさない
    static func hasMore(visibleMaxY: CGFloat, contentHeight: CGFloat, bottomPadding: CGFloat) -> Bool {
        visibleMaxY < contentHeight - bottomPadding - 0.5
    }

    /// 行を、行数と文字数の両方の上限でまとめる
    private static func grouped(_ lines: [String], maxLines: Int, maxChars: Int) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var chars = 0
        for line in lines {
            // 行を継ぐ改行も 1 字として数える
            if !current.isEmpty, (current.count == maxLines || chars + 1 + line.count > maxChars) {
                result.append(current.joined(separator: "\n"))
                current = []
                chars = 0
            }
            chars += (current.isEmpty ? 0 : 1) + line.count
            current.append(line)
        }
        if !current.isEmpty {
            result.append(current.joined(separator: "\n"))
        }
        return result
    }

    /// 長すぎる行を文の切れ目で分ける。文末が無ければ最後の空白、それも無ければ文字数で切る
    private static func sentences(_ line: String, maxChars: Int) -> [String] {
        guard line.count > maxChars else { return [line] }
        var result: [String] = []
        var rest = Substring(line)
        while rest.count > maxChars {
            let limit = rest.index(rest.startIndex, offsetBy: maxChars)
            let cut = sentenceCut(rest, limit: limit)
                ?? whitespaceCut(rest, limit: limit)
                ?? limit
            result.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty {
            result.append(String(rest))
        }
        return result
    }

    /// 文末の位置。「。」「！」「？」と、後ろが空白か行末の「.」「!」「?」だけを文末とみなす
    /// (`Ver.` や `1.1` の途中では切らない)
    private static func sentenceCut(_ text: Substring, limit: Substring.Index) -> Substring.Index? {
        var cut: Substring.Index?
        var index = text.startIndex
        while index < limit {
            if isSentenceEnd(text, at: index) {
                cut = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return cut
    }

    private static func isSentenceEnd(_ text: Substring, at index: Substring.Index) -> Bool {
        switch text[index] {
        case "。", "！", "？":
            return true
        case ".", "!", "?":
            let next = text.index(after: index)
            return next == text.endIndex || text[next].isWhitespace
        default:
            return false
        }
    }

    private static func whitespaceCut(_ text: Substring, limit: Substring.Index) -> Substring.Index? {
        var cut: Substring.Index?
        var index = text.startIndex
        while index < limit {
            if text[index].isWhitespace {
                cut = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return cut
    }
}

extension View {
    /// 画面の外に続きがあるときだけ、下端に「▼ 下キーで続き」を出す。
    /// - Parameter bottomPadding: 本文の下に足している余白 (`.padding(.bottom, n)` の n)
    func tvContinueHint(bottomPadding: CGFloat = 0) -> some View {
        modifier(TVContinueHint(bottomPadding: bottomPadding))
    }
}

private struct TVContinueHint: ViewModifier {
    let bottomPadding: CGFloat
    @State private var hasMore = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                TVReading.hasMore(
                    visibleMaxY: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height,
                    bottomPadding: bottomPadding
                )
            } action: { _, value in
                hasMore = value
            }
            .safeAreaInset(edge: .bottom) {
                if hasMore {
                    Text("▼ 下キーで続き")
                        .font(.callout)
                        .foregroundStyle(TVTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(TVTheme.background)
                }
            }
    }
}
