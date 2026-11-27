import SwiftUI

/// 番組表のタブ。MainTabView が置く。
struct GuideTab: View {
    @Environment(AppModel.self) private var app
    @State private var model: GuideModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GuideView(model: model)
                } else {
                    Color.clear
                }
            }
        }
        .task {
            if model == nil {
                model = GuideModel(app: app)
            }
        }
    }
}
