import SwiftUI

/// tvOS の接続先 (TV-Settings の行から開く)。ServerView と同じ動き。
struct TVServerView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("接続先")
                    .font(.system(size: 56, weight: .bold))

                Text("denpa のアドレス")
                    .font(.system(size: 26))
                    .foregroundStyle(TVTheme.muted)
                    .padding(.top, 36)

                HStack(spacing: 24) {
                    Text("アドレス")
                        .foregroundStyle(.white.opacity(0.7))
                    TextField("denpa.lan:3000", text: $address)
                        .textFieldStyle(.plain)
                        .onSubmit { reconnect() }
                }
                .font(.system(size: 30))
                .padding(.horizontal, 30)
                .frame(height: 86)
                .background(TVTheme.light, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(TVTheme.ink)

                Text("アドレスを変更して「再接続」を押すと、接続先を切り替えられます。")
                    .font(.system(size: 24))
                    .foregroundStyle(TVTheme.muted)
                Text("状態: \(statusText)")
                    .font(.system(size: 24))
                if let error {
                    Text(error)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 24) {
                    Button("再接続") {
                        reconnect()
                    }
                    .disabled(busy)
                    if model.isDemo {
                        Button("デモを終了", role: .destructive) {
                            Task { await model.signOut() }
                        }
                    } else if model.hasToken {
                        Button("接続を解除", role: .destructive) {
                            Task { await model.signOut() }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 18)
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.leading, 430)
            .padding(.top, 70)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            address = model.isDemo ? "" : (model.server?.displayName ?? model.address)
        }
    }

    private var statusText: String {
        if model.isDemo { return DemoServer.displayName }
        return model.server == nil ? String(localized: "未接続") : String(localized: "接続済み")
    }

    private func reconnect() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let message = await model.reconnect(address)
            busy = false
            if let message {
                error = message
            } else {
                address = model.server?.displayName ?? address
            }
        }
    }
}
