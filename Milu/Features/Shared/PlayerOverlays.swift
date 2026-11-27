import SwiftUI

/// 再生の画面の共通の重ね物 (iPhone/iPad/Apple TV)。ライブと録画で同じものを使う。
/// Apple TV は字が小さいので、呼ぶ側が `scale` で大きくする。

struct ReconnectOverlay: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.1)
                Text("再接続中…")
                    .scaledFont(16, weight: .semibold)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(.ultraThinMaterial, in: Capsule())
            .scaleEffect(scale)
        }
    }
}

struct PlayerErrorOverlay: View {
    let stop: PlaybackSession.Stop
    var scale: CGFloat = 1
    let retry: () -> Void

    private var title: String {
        switch stop.reason {
        case .noPlayableFormat: String(localized: "再生できる形式がありません")
        case .serverBusy: String(localized: "サーバーが混み合っています")
        case .emptyStream: String(localized: "映像を受信できませんでした")
        case .yielded: String(localized: "録画が始まったため視聴できません")
        case .refused: String(localized: "再生できません")
        }
    }

    private var message: String {
        switch stop.reason {
        case .noPlayableFormat:
            String(localized: "この \(DeviceName.name) に対応した映像形式がありません。")
        case .refused(let message):
            message
        default:
            ""
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .scaledFont(44, weight: .light)
                    .foregroundStyle(.orange)
                Text(title)
                    .scaledFont(20, weight: .bold)
                    .multilineTextAlignment(.center)
                if !message.isEmpty {
                    Text(message)
                        .scaledFont(14)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if stop.retry {
                    #if os(tvOS)
                    // Apple TV は外観・フォーカスを標準の ButtonStyle に任せる (#75)
                    Button("再試行", action: retry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 14)
                    #else
                    Button("再試行", action: retry)
                        .buttonStyle(SecondaryButtonStyle(height: 44))
                        .frame(width: 140)
                        .padding(.top, 14)
                    #endif
                }
            }
            .padding(.horizontal, 40)
            .scaleEffect(scale)
        }
    }
}
