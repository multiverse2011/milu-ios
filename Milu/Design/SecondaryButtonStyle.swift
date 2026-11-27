import SwiftUI

/// 画面案の控えめなボタン (50pt・角 25・薄い面に主の色の字)。
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    /// 削除など、赤で出す
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(17, weight: .semibold)
            .foregroundStyle(destructive ? Color(red: 1, green: 0.41, blue: 0.38) : Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    /// tvOS に `tertiarySystemFill` は無い
    private var fill: Color {
        #if os(tvOS)
        Color(white: 1).opacity(0.14)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }
}
