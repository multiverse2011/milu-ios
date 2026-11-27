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
        .tint(tint)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active)
        }
    }

    /// 押せる物の地の色。tvOS は標準の白地・黒字のフォーカスに揃えるため中立にし、
    /// 意味のある印は各画面が Color.accentColor を直に指定して残す
    private var tint: Color {
        #if os(tvOS)
        .primary
        #else
        Color.accentColor
        #endif
    }
}
