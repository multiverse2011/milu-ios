import SwiftUI

/// tvOS の局ロゴ。局名の頭 1 字で代える (TV-RecordingDetail)。
struct TVChannelLogo: View {
    let name: String

    var body: some View {
        Text(String(name.prefix(1)))
            // ロゴの枠 (70×40) に合わせて決まる字なので、枠の大きさに合わせる
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 70, height: 40)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// メニューのボタンの字 (項目名と今の値)。値が空なら項目名だけを出す
/// (音声の名前が空のときに「音声 音声」と重ねない)。
struct TVMenuLabel: View {
    let name: LocalizedStringKey
    let value: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            if let value, !value.isEmpty {
                Text(value)
            }
        }
        .lineLimit(1)
    }
}

/// 音声のラベルの受け皿。空なら nil にして、ボタンに値を出さない
func tvAudioValue(_ label: String?) -> String? {
    guard let label, !label.isEmpty else { return nil }
    return label
}

/// tvOS の標準のメニューの中の 1 行。選んでいるものにチェックを付け、読み上げにも選択を伝える。
/// 札 (pill) のように押すたびに値を回すのではなく、全部の値を並べて 1 つを選ばせる。
struct TVMenuOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
