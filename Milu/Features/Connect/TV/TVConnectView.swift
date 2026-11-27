import SwiftUI

/// tvOS の繋ぐ画面 (TV-Connect)。絵に無い失敗の行は iPhone と同じ場所に出す。
struct TVConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            VStack(spacing: 18) {
                Image("AppMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                Text("denpa に繋ぐ")
                    .font(.largeTitle.bold())
                    .padding(.top, 4)
                Text("家の denpa の Web 画面を開くときのアドレスを入れてください。\niPhone のキーボードからも打てます。")
                    .font(.title3)
                    .foregroundStyle(TVTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)

                // 地・枠・拡大は tvOS の TextField の既定の見た目に任せる
                HStack(spacing: 24) {
                    Text("アドレス")
                        .font(.title3)
                        .fontWeight(.medium)
                    TextField("denpa.lan", text: $model.address)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .onSubmit { connect() }
                }
                .padding(.top, 22)

                Group {
                    if let failure = model.failure {
                        Text(failureText(failure))
                            .foregroundStyle(.orange)
                    } else {
                        Text("例: denpa.lan、192.168.1.20:3000")
                            .foregroundStyle(TVTheme.muted)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)

                // 外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)
                Button(action: connect) {
                    Group {
                        if model.isConnecting {
                            ProgressView()
                        } else {
                            Text("繋ぐ")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isConnecting)
                .padding(.top, 8)
            }
            .frame(width: 1000)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 190)

            Text("Milu は denpa の非公式クライアントです。")
                .font(.callout)
                .foregroundStyle(TVTheme.muted)
                .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureText(_ failure: AppModel.Failure) -> String {
        switch failure {
        case .notFound:
            String(localized: "denpa が見つかりません。アドレスを確認してください。")
        case .message(let message):
            message
        }
    }

    private func connect() {
        Task { await model.connectField() }
    }
}
