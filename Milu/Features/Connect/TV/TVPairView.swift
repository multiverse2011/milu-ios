import SwiftUI

/// tvOS のペアリング (TV-Pair)。QR とコードを出して待つ。
/// Apple TV には Safari が無いので「この端末で許可」は出さない (D27)。
struct TVPairView: View {
    let pairing: PairingModel
    var onBack: (() -> Void)? = nil
    let onCancel: () -> Void

    private var host: String {
        pairing.serverURL.host ?? pairing.serverURL.absoluteString
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 120) {
                qrCode
                VStack(alignment: .leading, spacing: 22) {
                    Text("この Apple TV を許可する")
                        .font(.largeTitle.bold())
                    Text("\(host) はログインが要ります。\nスマホで QR を読み取り、denpa にログインして、\n出てきた画面でコードが同じことを確かめて許可してください。")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .lineSpacing(6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("コード")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(pairing.code?.userCode ?? "---- ----")
                            .font(.system(.largeTitle, design: .monospaced).bold())
                            .tracking(8)
                    }
                    .padding(.top, 14)
                    HStack(spacing: 16) {
                        if pairing.error == nil {
                            ProgressView()
                                .scaleEffect(1.4)
                        }
                        Text(pairing.error ?? String(localized: "許可を待っています"))
                            .foregroundStyle(pairing.error == nil ? Color.secondary : .orange)
                    }
                    .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 200)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)
            Button("接続先を変える") { onBack?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.bottom, 110)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { onBack?() }
        .onDisappear {
            // 画面を離れたら待ち受けを止める
            onCancel()
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        Group {
            if let verificationURL = pairing.verificationURL, let image = PairingQR.image(for: verificationURL) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                Text("QR コード")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(TVTheme.qrInk)
            }
        }
        .frame(width: 480, height: 480)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
    }
}
