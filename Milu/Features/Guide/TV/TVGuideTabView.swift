import SwiftUI

/// tvOS の番組表のタブ (TV-Guide)。
struct TVGuideTabView: View {
    @Environment(AppModel.self) private var app
    @State private var model: GuideModel?

    var body: some View {
        Group {
            if let model {
                TVGuideView(model: model)
            } else {
                Color.clear
            }
        }
        .task {
            if model == nil {
                model = GuideModel(app: app)
            }
        }
    }
}
