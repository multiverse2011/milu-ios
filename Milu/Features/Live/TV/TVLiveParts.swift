import SwiftUI

/// Apple TV のライブの部品 (TV-Live・TV-LiveHud・TV-LiveTuning・TV-LiveDetail)。

/// リモコンのフォーカスの的 (3.5.1)。操作の列は項目ごとに 1 つのメニューなので、
/// メニューの中の選択肢ではなく、メニューのボタンに当てる
enum TVLiveFocus: Hashable {
    case video
    /// 画質 (解像度もこのメニューの中)
    case quality
    case captions
    case audio
    case record
    case station(Int64)
    case detailRecord
    case detailClose
    /// 詳細の説明の続き (下キーで送るための置き場)
    case detailContinue
}

/// 局ロゴ。`logo` が無い・取れないときは、面に局名の頭 1 字。iPhone の ServiceLogo の tvOS の大きさ版。
struct TVServiceLogo: View {
    let service: Service
    let baseURL: URL?
    let token: String?
    var width: CGFloat = 70
    var height: CGFloat = 40

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(service.name.prefix(1)))
                    // ロゴの枠 (70×40) に合わせて決まる字なので、枠の高さから出す
                    .font(.system(size: height * 0.5, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: service.logo) { await load() }
    }

    private func load() async {
        guard
            !DemoServer.isDemo(baseURL),
            let logo = service.logo,
            let baseURL,
            let url = URL(string: logo, relativeTo: baseURL)
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
        else { return }
        image = loaded
    }
}

/// 局の頭の行 (メニューと帯で同じ)。`quality` を渡すと画質の文字を足す。
struct TVServiceHeader: View {
    let service: Service
    let baseURL: URL?
    let token: String?
    var quality: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 28) {
                TVServiceLogo(service: service, baseURL: baseURL, token: token, width: 106, height: 60)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        if let key = service.remoteControlKey {
                            Text("\(key)")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(service.name)
                            .font(.headline)
                        if let quality {
                            Text(quality)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 14) {
                        Text(service.now?.title ?? "")
                            .font(DenpaFont.font(.body))
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(TVLiveText.remaining(service.now, now: context.date))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// 番組の進みのバー (画面案 `--primary`、地は rgba(255,255,255,.22))
struct TVProgressBar: View {
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// ライブの番組の時刻と進み (Wording から出す)
enum TVLiveText {
    static func progress(_ program: CurrentProgram?, now: Date) -> Double {
        guard let program, program.endAt > program.startAt else { return 0 }
        let position = now.timeIntervalSince1970 * 1000
        return (position - Double(program.startAt)) / Double(program.endAt - program.startAt)
    }

    static func remaining(_ program: CurrentProgram?, now: Date) -> String {
        guard let program else { return "" }
        return Wording.remaining(
            program.endAt - Int64(now.timeIntervalSince1970 * 1000),
            kind: .ago
        )
    }

    /// 選んだ画質の名前。自動なら「自動 (いまの形式)」。形式が分からなければ「自動」。
    static func quality(selected: OfferCodec?, current: OfferCodec?, locale: Locale = .current) -> String {
        if let selected {
            return PlaybackRules.codecName(selected, locale: locale)
        }
        let auto = String(localized: LocalizedStringResource("自動", locale: locale))
        guard let current else { return auto }
        return "\(auto) (\(PlaybackRules.codecName(current, locale: locale)))"
    }

    static func quality(_ session: PlaybackSession?, locale: Locale = .current) -> String {
        quality(selected: session?.selectedQuality, current: session?.currentCodec, locale: locale)
    }

    /// 画質のボタンの名前 (画面案 TV-Live)。自動のボタンにいまの形式を添える。
    static func qualityItemTitle(_ item: PlaybackRules.QualityItem, session: PlaybackSession?, locale: Locale = .current) -> String {
        if let codec = item.codec {
            return PlaybackRules.codecName(codec, locale: locale)
        }
        return quality(selected: nil, current: session?.currentCodec, locale: locale)
    }

    /// 左右で前後の局を選ぶ。端は回り込む (3.5.1)
    static func neighbor(of current: Service?, in services: [Service], by delta: Int) -> Service? {
        guard !services.isEmpty else { return nil }
        guard let current, let index = services.firstIndex(where: { $0.id == current.id }) else {
            return services.first
        }
        return services[(index + delta + services.count) % services.count]
    }
}
