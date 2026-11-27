import SwiftUI

/// 放送の字 (D9)。番組名・局名・説明・字幕・番組表のマスに使う。アプリの字は端末の字。
nonisolated enum DenpaFont {
    static let postScriptName = "DenpaFont-Regular"

    static func font(size: CGFloat) -> Font {
        .custom(postScriptName, size: size, relativeTo: .body)
    }
}

/// 端末の字。標準の大きさでは今までと同じ大きさで、Dynamic Type に従って拡大する
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight?, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight ?? .regular
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// `.font(.system(size:))` の代わり。標準の大きさでは同じ見た目
    func scaledFont(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
