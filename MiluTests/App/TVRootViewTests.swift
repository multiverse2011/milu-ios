#if os(tvOS)
import Foundation
import Testing
@testable import Milu

@Suite @MainActor struct TVRootViewTests {
    private var url: URL { URL(string: "http://127.0.0.1:3000")! }
    private var paired: PairingModel { PairingModel(serverURL: url) { _ in } }

    /// 接続先が無くてもペアリング中なら TV-Pair を出す (iPhone/iPad の RootView と同じ順)
    @Test func pairingWinsWhenThereIsNoServer() {
        #expect(TVRootView.screen(server: nil, pairing: paired) == .pair)
    }

    /// 接続済みから 401 でペアリングに戻ったときも TV-Pair を出す
    @Test func pairingWinsWhenConnected() {
        let connection = ServerConnection(url: url, token: "old")
        #expect(TVRootView.screen(server: connection, pairing: paired) == .pair)
    }

    @Test func noServerWithoutPairingShowsConnect() {
        #expect(TVRootView.screen(server: nil, pairing: nil) == .connect)
    }

    @Test func connectedWithoutPairingShowsMain() {
        let connection = ServerConnection(url: url, token: nil)
        #expect(TVRootView.screen(server: connection, pairing: nil) == .main)
    }
}
#endif
