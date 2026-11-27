import SwiftUI

extension Recording {
    /// サムネイルの観た割合。未視聴 (続きも視聴済みの印も無い) は出さない
    nonisolated var posterWatchedFraction: Double? {
        guard resumeMs != nil || watchedAt != nil else { return nil }
        return RecordingRules.watchedFraction(resumeMs: resumeMs, durationMs: durationMs)
    }
}

/// 録画のサムネイル (3.5)。`poster` が無い・取れないときは面の色に番組名。
/// 検索の行も同じ部品を使う (検索の行は `poster` を返さないので、一覧と同じ道を呼び手が組む。D31)。
struct RecordingPoster: View {
    /// `api/recordings/<id>/poster` の相対 URL
    let poster: String?
    /// サムネイルが無い・取れないときの控えの字
    let title: String
    let baseURL: URL?
    let token: String?
    /// 観た割合 (0...1)。出さないときは nil
    var watchedFraction: Double?
    var width: CGFloat = 96
    var height: CGFloat = 54
    var corner: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(title)
                    .font(DenpaFont.font(size: max(8, width * 0.11)))
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(fallbackColor)
            }
            if let fraction = watchedFraction {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * fraction, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .task(id: poster) { await load() }
    }

    private var fallbackColor: Color {
        // ポスターが取れないときは面の色に番組名を置く (3.5)
        Color(uiColor: .secondarySystemBackground)
    }

    private func load() async {
        guard
            !DemoServer.isDemo(baseURL),
            let poster,
            let baseURL,
            let url = URL(string: poster, relativeTo: baseURL)
        else {
            image = nil
            return
        }
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let loaded = UIImage(data: data)
        else {
            image = nil
            return
        }
        image = trimmed(loaded)
    }

    /// 放送の上下に焼かれた黒帯を落とす。16:9 に切り抜いたとき帯を見せないため
    private func trimmed(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return image }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return image }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func brightRow(_ y: Int) -> Bool {
            var x = 0
            while x < width {
                let index = (y * width + x) * 4
                if pixels[index] > 24 || pixels[index + 1] > 24 || pixels[index + 2] > 24 {
                    return true
                }
                x += 2
            }
            return false
        }
        var top = 0
        while top < height / 4, !brightRow(top) { top += 1 }
        var bottom = height - 1
        while bottom > height * 3 / 4, !brightRow(bottom) { bottom -= 1 }
        guard top > 0 || bottom < height - 1, bottom - top > height / 3 else { return image }
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top + 1)) else {
            return image
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
