import AuthenticationServices
import SwiftUI

/// ペアリングの画面 (3.5・iPhone-Pair)。QR とコードを出し、許可を待つ。
struct PairView: View {
    let pairing: PairingModel
    var onBack: (() -> Void)? = nil
    let onCancel: () -> Void

    @State private var webSession: ASWebAuthenticationSession?
    @State private var context = WebAuthContext()

    private var host: String {
        pairing.serverURL.host ?? pairing.serverURL.absoluteString
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("この \(DeviceName.name) を許可")
                        .scaledFont(28, weight: .bold)
                        .multilineTextAlignment(.center)
                    Text("\(host) にはログインが必要です。\ndenpa にログインして、この \(DeviceName.name) を許可してください。")
                        .scaledFont(15)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                Button("この \(DeviceName.name) で許可", action: startWeb)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.top, 26)

                Text("ほかの端末で許可する場合")
                    .scaledFont(13)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 30)
                    .padding(.bottom, 6)

                VStack(spacing: 14) {
                    qrCode
                    VStack(spacing: 2) {
                        Text("コード")
                            .scaledFont(12.5)
                            .foregroundStyle(.secondary)
                        Text(pairing.code?.userCode ?? "---- ----")
                            .scaledFont(30, weight: .bold, design: .monospaced)
                            .tracking(3)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 18)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 16)

                Text("QR コードを読み取り、表示された画面でコードが一致していることを確認して許可してください。")
                    .scaledFont(12.5)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if pairing.error == nil {
                    ProgressView()
                }
                Text(pairing.error ?? String(localized: "許可を待っています…"))
                    .scaledFont(14)
                    .foregroundStyle(pairing.error == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .scaledFont(17, weight: .semibold)
                    }
                    .tint(.primary)
                    .accessibilityLabel("戻る")
                }
            }
        }
        .onDisappear {
            // 画面を離れたら待ち受けを止める。PairView からさらに push する画面を足すときは見直す
            webSession?.cancel()
            webSession = nil
            onCancel()
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let image = qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(width: 168, height: 168)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("QR コード")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(Color(red: 0.235, green: 0.235, blue: 0.263))
                .frame(width: 168, height: 168)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var qrImage: UIImage? {
        guard let verificationURL = pairing.verificationURL else { return nil }
        return PairingQR.image(for: verificationURL)
    }

    private func startWeb() {
        guard let verificationURL = pairing.verificationURL else { return }
        let session = ASWebAuthenticationSession(url: verificationURL, callbackURLScheme: nil) { _, _ in }
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        session.start()
    }
}

/// `ASWebAuthenticationSession` を画面に出すための窓 (4.2)
final class WebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // 画面から出しているのでシーンは必ずある
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        return scene.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scene)
    }
}
