import SwiftUI

/// tvOS のライセンス (TV-Licenses)。Denpa Font の説明と OFL 1.1 の全文。
struct TVLicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ライセンス")
                    .font(.system(size: 56, weight: .bold))
                Text("Denpa Font")
                    .font(.system(size: 36, weight: .bold))
                    .padding(.top, 24)
                Text("番組名・局名・字幕の字に使っています。SIL Open Font License 1.1 で配られています。")
                    .font(.system(size: 26))
                    .foregroundStyle(TVTheme.muted)
                TVReadingText(
                    text: AppInfo.license,
                    font: .system(size: 24, design: .monospaced),
                    lineSpacing: 8
                )
                .foregroundStyle(TVTheme.body)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 430)
            .padding(.trailing, 250)
            .padding(.top, 70)
        }
        .tvContinueHint()
    }
}
