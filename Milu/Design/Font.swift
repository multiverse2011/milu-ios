import SwiftUI
import UIKit

/// 放送の字 (D9)。番組名・局名・説明・字幕・番組表のマスに使う。アプリの字は端末の字。
nonisolated enum DenpaFont {
    static let postScriptName = "DenpaFont-Regular"

    static func font(size: CGFloat) -> Font {
        .custom(postScriptName, size: size, relativeTo: .body)
    }

    /// 放送の字を、アプリの字と同じテキストスタイルの大きさに揃える (TV の画面)。
    /// 端末の文字の大きさの設定にも、システム書体と同じように従う
    static func font(_ style: Font.TextStyle) -> Font {
        .custom(postScriptName, size: baseSize(of: style), relativeTo: style)
    }

    /// 標準の大きさのときの値を、いまの設定から割り出す。OS ごとに変わる値を直書きしない
    private static func baseSize(of style: Font.TextStyle) -> CGFloat {
        let uiStyle = uiStyle(style)
        let scale = UIFontMetrics(forTextStyle: uiStyle).scaledValue(for: 100) / 100
        return UIFont.preferredFont(forTextStyle: uiStyle).pointSize / scale
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        // tvOS に largeTitle は無い。放送の字では使わない
        case .largeTitle: .body
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
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
