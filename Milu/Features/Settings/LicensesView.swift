import SwiftUI

/// ライセンス (3.5・iPhone-Licenses)。Denpa Font の説明と OFL 1.1 の全文。
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Denpa Font")
                    .scaledFont(20, weight: .bold)
                Text("番組名・放送局名・字幕の表示に使用しています。SIL Open Font License 1.1 のもとで提供されています。")
                    .scaledFont(13.5)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                Text(AppInfo.license)
                    .scaledFont(12, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("ライセンス")
        .navigationBarTitleDisplayMode(.inline)
    }
}
