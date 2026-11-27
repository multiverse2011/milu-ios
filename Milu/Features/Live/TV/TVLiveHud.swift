import SwiftUI

/// 左右で局を替えた直後の下の帯と、選局中の帯 (TV-LiveHud・TV-LiveTuning)
struct TVLiveBand: View {
    /// 帯の高さ。字幕を持ち上げる量 (TVLiveTabView) がこれを使う。
    /// 中の行 (~75) + 下余白 28 + バー 6 + 下余白 64
    static let height: CGFloat = 173

    let service: Service?
    let baseURL: URL?
    let token: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if let service {
                TVServiceHeader(service: service, baseURL: baseURL, token: token)
                    .padding(.bottom, 28)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TVProgressBar(value: TVLiveText.progress(service.now, now: context.date))
                        .padding(.bottom, 64)
                }
            }
        }
        .padding(.horizontal, 96)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, TVTheme.scrim.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 420)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}
