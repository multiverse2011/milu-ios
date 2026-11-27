import SwiftUI

/// 設定 (3.5・iPhone-Settings・iPad-Settings)。denpa の版は出さない (D21)。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(OrientationLock.autoLandscapeKey) private var autoLandscapePlayback = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServerView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .scaledFont(18)
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.server?.displayName ?? String(localized: "接続先"))
                            Text("接続先の変更")
                                .scaledFont(12.5)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("接続先")
            }

            if DeviceName.isPhone {
                Section {
                    Toggle("再生時に自動で横画面にする", isOn: $autoLandscapePlayback)
                } header: {
                    Text(String(localized: "再生 (設定)", defaultValue: "再生"))
                }
            }

            Section {
                LabeledContent("バージョン", value: AppInfo.version)
                NavigationLink("ライセンス") {
                    LicensesView()
                }
                externalLink("プライバシーポリシー", destination: AppLinks.privacyPolicy)
            } header: {
                Text("このアプリについて")
            } footer: {
                Text("Milu は denpa の非公式クライアントです。")
            }
        }
        .frame(maxWidth: 680)
        .navigationTitle("設定")
    }

    private func externalLink(_ title: LocalizedStringKey, destination: URL) -> some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .foregroundStyle(Color(uiColor: .label))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}
