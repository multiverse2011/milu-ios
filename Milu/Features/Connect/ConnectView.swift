import SwiftUI

/// 繋ぐ画面 (3.5・iPhone-Connect・iPhone-ConnectError・iPad-Connect)
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    private var isPad: Bool { DeviceName.isPad }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Spacer(minLength: 36)

            VStack(spacing: 10) {
                Image("AppMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: isPad ? 84 : 76, height: isPad ? 84 : 76)
                    .clipShape(RoundedRectangle(cornerRadius: isPad ? 20 : 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: isPad ? 20 : 18)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    }
                Text("denpa に接続")
                    .scaledFont(isPad ? 30 : 28, weight: .bold)
                    .padding(.top, 4)
                Text("ブラウザで denpa を開くときのアドレスを入力してください。")
                    .scaledFont(isPad ? 16 : 15)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 40)

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("アドレス")
                        .foregroundStyle(.secondary)
                    TextField("denpa.lan", text: $model.address)
                        .scaledFont(16)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { connect() }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))

                if let failure = model.failure {
                    failureView(failure)
                } else {
                    Text("例: denpa.lan、192.168.1.20:3000")
                        .scaledFont(12.5)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 7)
                        .padding(.horizontal, 16)
                }

                Button(action: connect) {
                    if model.isConnecting {
                        ProgressView()
                            .tint(Color(red: 0, green: 0.075, blue: 0.122))
                    } else {
                        Text("接続")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isConnecting)
                .opacity(model.isConnecting ? 0.75 : 1)
                .padding(.top, 22)

                Button("デモで試す") {
                    model.startDemo()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isConnecting)
                .padding(.top, 12)
            }
            .frame(maxWidth: 440)

            Spacer(minLength: 28)

            VStack(spacing: 4) {
                Text("Milu は denpa の非公式クライアントです。")
                    .scaledFont(12.5)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                footerLink("プライバシーポリシー", destination: AppLinks.privacyPolicy)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 16)
        .navigationDestination(item: pairingDestination) { pairing in
            PairView(
                pairing: pairing,
                onCancel: { model.cancelPairing(pairing) }
            )
        }
    }

    private func footerLink(_ title: LocalizedStringKey, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 3) {
                Text(title)
                    .scaledFont(12.5)
                Image(systemName: "arrow.up.right")
                    .scaledFont(10.5, weight: .semibold)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .padding(.vertical, 4)
        }
        .tint(.primary)
    }

    private var pairingDestination: Binding<PairingModel?> {
        Binding(
            get: { model.pairing },
            set: { newValue in
                // pop されたときの nil だけを受ける
                if newValue == nil {
                    model.cancelPairing()
                }
            }
        )
    }

    @ViewBuilder
    private func failureView(_ failure: AppModel.Failure) -> some View {
        switch failure {
        case .notFound:
            VStack(alignment: .leading, spacing: 4) {
                Text("denpa が見つかりません")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(.orange)
                Text("アドレスを確認してください。正しいのに接続できない場合は、「設定」の「ローカルネットワーク」で Milu を許可してください。")
                    .scaledFont(12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
            .padding(.horizontal, 16)
        case .message(let message):
            Text(message)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
                .padding(.horizontal, 16)
        }
    }

    private func connect() {
        Task { await model.connectField() }
    }
}
