import SwiftUI

/// tvOS の設定 (TV-Settings)。denpa の版は出さない (D21)。
struct TVSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("設定")
                    .font(.system(size: 56, weight: .bold))

                Text("接続先")
                    .font(.system(size: 26))
                    .foregroundStyle(TVTheme.muted)
                    .padding(.top, 36)

                TVSettingsRow(label: model.server?.displayName ?? String(localized: "接続先"), value: String(localized: "押すと接続先を変えます")) {
                    TVServerView()
                }

                Text("このアプリについて")
                    .font(.system(size: 26))
                    .foregroundStyle(TVTheme.muted)
                    .padding(.top, 36)

                TVSettingsInfoRow(label: String(localized: "バージョン"), value: AppInfo.version)
                TVSettingsRow(label: String(localized: "ライセンス"), value: "›") {
                    TVLicensesView()
                }

                Text("Milu は denpa の非公式クライアントです。")
                    .font(.system(size: 24))
                    .foregroundStyle(TVTheme.muted)
                    .padding(.top, 18)
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.leading, 430)
            .padding(.top, 70)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func rowContent(label: String, value: String) -> some View {
    HStack(spacing: 20) {
        Text(label)
            .font(.system(size: 30, weight: .semibold))
        Spacer()
        Text(value)
            .font(.system(size: 30))
            // 標準の ButtonStyle はフォーカス時にラベルの色を変えるので、固定の灰ではなく
            // その字の色に従わせる (押せない行でも同じ濃さで読める)
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 30)
    .frame(height: 86)
}

/// TV-Settings の押せる行。外観とフォーカスは tvOS の標準の ButtonStyle に任せる (#75)。
private struct TVSettingsRow<Destination: View>: View {
    let label: String
    let value: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            rowContent(label: label, value: value)
        }
        .buttonStyle(.bordered)
    }
}

/// TV-Settings の押せない行 (バージョン)。
private struct TVSettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        rowContent(label: label, value: value)
            .background(TVTheme.fill, in: RoundedRectangle(cornerRadius: 18))
    }
}
