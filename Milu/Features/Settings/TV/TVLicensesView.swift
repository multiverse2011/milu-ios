import SwiftUI

/// tvOS のライセンス (TV-Licenses)。Denpa Font の説明と OFL 1.1 の全文。
struct TVLicensesView: View {
    var body: some View {
        List {
            Section("Denpa Font") {
                Text("番組名・局名・字幕の字に使っています。SIL Open Font License 1.1 で配られています。")
                    .foregroundStyle(.secondary)
            }

            Section {
                TVReadingText(
                    text: AppInfo.license,
                    font: .system(.footnote, design: .monospaced),
                    lineSpacing: 8
                )
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("ライセンス")
        .tvContinueHint()
    }
}
