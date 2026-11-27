import SwiftUI

/// 接続先 (3.5・iPhone-Server)。繋ぎ直しと「サーバーから外す」。
struct ServerView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Text("アドレス")
                        .foregroundStyle(.secondary)
                    TextField("denpa.lan:3000", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { reconnect() }
                }
                LabeledContent("状態", value: statusText)
            } header: {
                Text("denpa のアドレス")
            } footer: {
                Text("アドレスを変更して「再接続」をタップすると、接続先を切り替えられます。")
            }

            if let error {
                Section {
                    Text(error)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    reconnect()
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Text("再接続")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(busy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }

            if model.isDemo {
                Section {
                    Button("デモを終了", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } footer: {
                    Text("デモを終了して、接続画面に戻ります。")
                }
            } else if model.hasToken {
                Section {
                    Button("接続を解除", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } header: {
                    Text("この \(DeviceName.name) の許可")
                } footer: {
                    Text("denpa に登録したこの \(DeviceName.name) の許可を取り消して、接続画面に戻ります。録画や予約は消えません。")
                }
            }
        }
        .navigationTitle("接続先")
        .navigationBarTitleDisplayMode(.inline)
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
