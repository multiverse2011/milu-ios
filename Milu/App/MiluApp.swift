import SwiftUI

@main
struct MiluApp: App {
    #if os(iOS)
    // 向きの返事は iPhone だけが要る (3.5.3)
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif
    @State private var model: AppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(AppModel.uiTestDemoArgument) {
            _model = State(initialValue: AppModel.makeForLaunch())
            return
        }
        #endif
        // 接続先を読み出すより前に、前の版が残したものを 1 度だけ消す (D14)
        Migration.runIfNeeded()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
