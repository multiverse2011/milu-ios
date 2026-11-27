import SwiftUI

/// tvOS の局ロゴ。局名の頭 1 字で代える (TV-RecordingDetail)。
struct TVChannelLogo: View {
    let name: String

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 70, height: 40)
            .background(Color.accentColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}
