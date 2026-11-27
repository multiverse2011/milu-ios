import SwiftUI

/// 接続前は繋ぐ画面、ペアリング中はその画面、繋いだらタブ (3.5)。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            #if os(tvOS)
            TVRootView()
            #else
            // 初回は ConnectView の NavigationStack に push、接続済みからの再ペアリングはここでルートに出す
            if model.server == nil {
                NavigationStack {
                    ConnectView()
                }
            } else if let pairing = model.pairing {
                NavigationStack {
                    PairView(
                        pairing: pairing,
                        onBack: { model.cancelPairing(pairing) },
                        onCancel: { model.cancelPairing(pairing) }
                    )
                }
            } else {
                MainTabView()
                    .id(model.server?.url)
            }
            #endif
        }
        .appTint()
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active)
        }
    }
}

private extension View {
    /// 押せる物の tint。tvOS は tint を付けるとフォーカス時の地と字の両方に効き、
    /// 白地に白字になりうるので付けない (標準のボタンの白地・黒字に任せる)。
    /// 意味のある印は各画面が Color.accentColor を直に指定して残す
    @ViewBuilder func appTint() -> some View {
        #if os(tvOS)
        self
        #else
        self.tint(Color.accentColor)
        #endif
    }
}
