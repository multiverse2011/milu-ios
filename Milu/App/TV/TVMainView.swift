import SwiftUI

/// 接続後の骨組み。左のサイドバーに 検索・録画・番組表・ライブ・設定 (TV-Recordings・TV-Search・Main.dc.html)。
/// 検索はサイドバーの先頭 (3.5・D31)。
struct TVMainView: View {
    private enum Selection: Hashable {
        case search
        case recordings
        case guide
        case live
        case settings
    }

    @Environment(AppModel.self) private var model
    @State private var selection: Selection = .recordings

    var body: some View {
        TabView(selection: $selection) {
            Tab(value: Selection.search, role: .search) {
                TVSearchView()
            }
            Tab("録画", systemImage: "play.rectangle", value: Selection.recordings) {
                TVRecordingsTabView(onGoLive: { selection = .live })
            }
            Tab("番組表", systemImage: "calendar", value: Selection.guide) {
                TVGuideTabView()
            }
            Tab("ライブ", systemImage: "antenna.radiowaves.left.and.right", value: Selection.live) {
                TVLiveTabView(isSelected: selection == .live)
            }
            Tab("設定", systemImage: "gearshape", value: Selection.settings) {
                NavigationStack {
                    TVSettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: model.liveWatch) { _, request in
            // 番組表の「ライブで観る」。ライブのタブへ移る (映す局は TVLiveTabView が受け取る)
            if request != nil {
                selection = .live
            }
        }
    }
}
