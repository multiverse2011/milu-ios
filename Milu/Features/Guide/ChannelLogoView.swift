import SwiftUI

/// 局ロゴ。`logo` の画像を Bearer を付けて取り、`null` なら控えた面に局名の頭 1 字 (3.5)。
struct ChannelLogoView: View {
    let path: String?
    let serviceName: String
    var width: CGFloat = 30
    var height: CGFloat = 17

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    /// 一度取った絵は種別を切り替えても使い回す (切り替えのたびに 54 局ぶん取り直さない)。
    /// 別の denpa に繋ぎ直したときに混ざらないよう、接続先ごとに持つ
    private static var cache: [String: UIImage] = [:]

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(serviceName.prefix(1))
                    .scaledFont(height * 0.6, weight: .bold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .background(logoBackground, in: RoundedRectangle(cornerRadius: 5))
        .task(id: path) {
            await load()
        }
    }

    /// tvOS に `tertiarySystemFill` は無い (TV-Guide と番組の詳細でも使うため tvOS のビルドにも入れる)
    private var logoBackground: Color {
        #if os(tvOS)
        Color.white.opacity(0.12)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }

    private func load() async {
        image = nil
        guard let path, !path.isEmpty else { return }
        let key = "\(app.server?.host ?? "")|\(path)"
        if let cached = Self.cache[key] {
            image = cached
            return
        }
        do {
            let data = try await app.get(path)
            guard let loaded = UIImage(data: data) else { return }
            Self.cache[key] = loaded
            image = loaded
        } catch {
            image = nil
        }
    }
}
