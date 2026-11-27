import SwiftUI

/// タブは 録画・番組表・ライブ・設定 の順 (3.5)。検索は録画の画面の中にある (D32)。
struct MainTabView: View {
    @Environment(AppModel.self) private var model

    private enum Selection: Hashable {
        case recordings
        case guide
        case live
        case settings
    }

    @State private var selection: Selection = .recordings

    var body: some View {
        TabView(selection: $selection) {
            Tab("録画", systemImage: "play.rectangle", value: Selection.recordings) {
                RecordingsView()
            }
            Tab("番組表", systemImage: "calendar", value: Selection.guide) {
                GuideTab()
            }
            Tab("ライブ", systemImage: "antenna.radiowaves.left.and.right", value: Selection.live) {
                LiveView(isSelected: selection == .live)
            }
            Tab("設定", systemImage: "gearshape", value: Selection.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .onChange(of: model.liveWatch) { _, request in
            // 「ライブで観る」。ライブのタブへ移る (映す局は LiveView が受け取る)
            if request != nil {
                selection = .live
            }
        }
    }
}
