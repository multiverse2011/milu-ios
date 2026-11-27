import SwiftUI

/// tvOS の設定 (TV-Settings)。denpa の版は出さない (D21)。純正の設定と同じ List の行にする。
struct TVSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("接続先") {
                NavigationLink {
                    TVServerView()
                } label: {
                    LabeledContent(model.server?.displayName ?? String(localized: "接続先")) {
                        Text("押すと接続先を変えます")
                    }
                }
            }

            Section("このアプリについて") {
                LabeledContent(String(localized: "バージョン"), value: AppInfo.version)
                NavigationLink(String(localized: "ライセンス")) {
                    TVLicensesView()
                }
            }

            Section {
                Text("Milu は denpa の非公式クライアントです。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
    }
}
