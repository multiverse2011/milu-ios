import SwiftUI

/// tvOS のライセンス (TV-Licenses)。Denpa Font の説明と OFL 1.1 の全文。
/// 長文を塊ごとに下キーで送るので、行ではなく ScrollView に置く。
struct TVLicensesView: View {
    var body: some View {
        let verticalPadding: CGFloat = 40
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Denpa Font")
                    .font(.headline)
                Text("番組名・局名・字幕の字に使っています。SIL Open Font License 1.1 で配られています。")
                    .foregroundStyle(.secondary)
                TVReadingText(
                    text: AppInfo.license,
                    font: .system(.footnote, design: .monospaced),
                    lineSpacing: 8,
                    scalesWithTextSize: true
                )
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, verticalPadding)
        }
        .navigationTitle("ライセンス")
        .tvContinueHint(bottomPadding: verticalPadding)
    }
}
