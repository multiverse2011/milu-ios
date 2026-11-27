import SwiftUI

/// tvOS の入口。接続前は TV-Connect、ペアリング中は TV-Pair、繋いだら左のサイドバー (D27)。
struct TVRootView: View {
    enum Screen: Equatable {
        case pair
        case connect
        case main
    }

    @Environment(AppModel.self) private var model

    /// ペアリングは接続の有無より先に見る。接続済みから 401 でペアリングに戻ったときも TV-Pair を出す
    static func screen(server: ServerConnection?, pairing: PairingModel?) -> Screen {
        if pairing != nil {
            return .pair
        }
        if server == nil {
            return .connect
        }
        return .main
    }

    var body: some View {
        Group {
            switch Self.screen(server: model.server, pairing: model.pairing) {
            case .pair:
                if let pairing = model.pairing {
                    TVPairView(
                        pairing: pairing,
                        onBack: { model.cancelPairing(pairing) },
                        onCancel: { model.cancelPairing(pairing) }
                    )
                }
            case .connect:
                TVConnectView()
            case .main:
                TVMainView()
                    .id(model.server?.url)
            }
        }
        .background(TVTheme.background)
    }
}
