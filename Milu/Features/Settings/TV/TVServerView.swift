import SwiftUI

/// tvOS の接続先 (TV-Settings の行から開く)。ServerView と同じ動き。
struct TVServerView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("denpa.lan:3000", text: $address)
                    .onSubmit { reconnect() }
            } header: {
                Text("denpa のアドレス")
            } footer: {
                Text("アドレスを変更して「再接続」を押すと、接続先を切り替えられます。")
            }

            Section {
                LabeledContent(String(localized: "状態"), value: statusText)
                if let error {
                    Text(error)
                        .foregroundStyle(.orange)
                }
            }

            Section {
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
        }
        .navigationTitle("接続先")
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
