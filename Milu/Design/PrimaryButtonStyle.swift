import SwiftUI

/// 画面案の大きなボタン (50pt・角 25・主の色に濃い字)。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(17, weight: .semibold)
            .foregroundStyle(Color(red: 0, green: 0.075, blue: 0.122))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.accentColor, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
