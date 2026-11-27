import UIKit

/// 録画の一覧と検索の結果をカードで出すか (3.5)。iPhone とコンパクト幅は行。
/// キーボードや検索の表示で View の表示領域が縮んでも向きが変わらないよう、
/// 表示領域ではなくウィンドウの大きさで決める (issue #65)
@MainActor
enum WindowShape {
    static var windowSize: CGSize {
        // 画面を 1 つだけ持つアプリなので先頭のシーンで足りる
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.effectiveGeometry.coordinateSpace.bounds.size ?? .zero
    }

    nonisolated static func isWide(isPad: Bool, isRegularWidth: Bool, window: CGSize) -> Bool {
        isPad && isRegularWidth && window.width > window.height
    }
}
