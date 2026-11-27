import SwiftUI

/// 一覧を取れなかったとき (3.5・iPhone-Offline)。録画・番組表・ライブで使う。
struct OfflineView: View {
    let host: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .scaledFont(56, weight: .light)
                .foregroundStyle(.secondary)
            Text("denpa に接続できません")
                .scaledFont(22, weight: .bold)
                .padding(.top, 8)
            Text("\(host) から応答がありません。\nWi-Fi などの接続状況を確認してください。")
                .scaledFont(15)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Button("再試行", action: retry)
                .buttonStyle(SecondaryButtonStyle(height: 44))
                .frame(width: 120)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}
