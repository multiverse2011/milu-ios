import SwiftUI

/// tvOS の録画のタブ (TV-Recordings・TV-RecordingsEmpty)。上に焦点の当たっている録画の大きな情報と背景、
/// 下に日付ごとのカードの列。決定の長押しでメニューを出し、「詳細」で詳細 (TV-RecordingDetail)。
struct TVRecordingsTabView: View {
    /// 録画がまだ無いときの「ライブへ」
    var onGoLive: () -> Void = {}

    @Environment(AppModel.self) private var app
    @State private var model = RecordingsModel()
    @FocusState private var focused: Int64?
    @State private var cover: Cover?
    @State private var alertMessage: String?

    /// 詳細と再生は 1 つの cover で切り替える。2 枚の fullScreenCover を同じ更新で入れ替えない
    /// (SwiftUI は前の提示の後始末の前に次の提示を出すと落ちることがある)
    private enum Cover: Identifiable {
        case detail(Recording)
        case watch(TVWatchRequest)

        var id: String {
            switch self {
            case .detail(let recording): "detail-\(recording.id)"
            case .watch(let request): "watch-\(request.id)"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            content
        }
        .task { await model.start(app) }
        .onDisappear { model.stop() }
        .fullScreenCover(item: $cover) { cover in
            switch cover {
            case .detail(let recording):
                TVRecordingDetailView(
                    recording: recording,
                    onPlay: { from in open(recording, from: from) },
                    onDelete: {
                        self.cover = nil
                        Task { await delete(recording) }
                    },
                    onClose: { self.cover = nil }
                )
                .background(TVTheme.background)
            case .watch(let request):
                TVRecordingPlayerView(session: request.session) {
                    self.cover = nil
                    Task { await model.refreshFromEvents() }
                }
            }
        }
        .alert("削除できません", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if model.load == .loading, model.recordings.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.load == .offline {
            TVOfflineView {
                Task { await model.reload() }
            }
        } else if model.load == .empty {
            emptyView
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                heroBlock
                ForEach(model.sections, id: \.date) { section in
                    VStack(alignment: .leading, spacing: 16) {
                        dateHeading(section.date)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 48) {
                                ForEach(section.entries) { recording in
                                    card(recording)
                                }
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 4)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
            // 左の余白は TabView(.sidebarAdaptable) の安全領域に任せる
            .padding(.trailing, 40)
            .padding(.top, 56)
            .padding(.bottom, 60)
        }
    }

    /// 焦点の当たっている録画の大きな情報 (絵の上のほう)
    @ViewBuilder
    private var heroBlock: some View {
        if let recording = hero {
            VStack(alignment: .leading, spacing: 16) {
                // 字の間は画面案の全角の空き。文言そのものには入れない (訳す鍵を汚さない)
                HStack(spacing: 14) {
                    Text("録画")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                    Text("長押しでメニューから詳細")
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 12, height: 12)
                        Text("まだ観ていない")
                    }
                    .padding(.leading, 8)
                }
                .font(.system(size: 26))
                .foregroundStyle(TVTheme.muted)

                HStack(spacing: 16) {
                    unseenDot(recording, size: 24)
                    Text(recording.title)
                        .font(DenpaFont.font(size: 56))
                        .fontWeight(.bold)
                        .lineLimit(2)
                }
                Text(metaLine(recording))
                    .font(.system(size: 30))
                    .foregroundStyle(Color(white: 0.92).opacity(0.86))
                if recording.recording {
                    Text("● 録画中")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.red, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 110, weight: .light))
                .foregroundStyle(TVTheme.muted)
            Text("録画はまだありません")
                .font(.system(size: 48, weight: .bold))
                .padding(.top, 10)
            Text("番組表で番組を予約すると、録れたものがここに並びます。")
                .font(.system(size: 30))
                .foregroundStyle(TVTheme.muted)
            Button("ライブへ", action: onGoLive)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dateHeading(_ date: Date) -> some View {
        let heading = Wording.dateHeadingParts(date, reference: Date())
        return HStack(spacing: 6) {
            Text(heading.primary)
            Text(heading.secondary)
                .foregroundStyle(TVTheme.muted)
        }
        .font(.system(size: 28))
        .foregroundStyle(Color(white: 0.92).opacity(0.86))
    }

    // MARK: - カード

    private func card(_ recording: Recording) -> some View {
        // 浮き上がり・影は tvOS の標準のボタンと hoverEffect に任せ、決定で再生・長押しでメニューを出す
        return Button {
            open(recording, from: nil)
        } label: {
            TVRecordingCard(
                title: recording.title,
                meta: cardMeta(recording),
                poster: recording.poster,
                unseen: unseen(recording),
                recording: recording.recording,
                baseURL: app.server?.url,
                token: app.server?.token
            )
        }
        .buttonStyle(.borderless)
        .focused($focused, equals: recording.id)
        .contextMenu {
            Button("詳細") { cover = .detail(recording) }
        }
        .onAppear {
            Task { await model.loadMoreIfNeeded(current: recording) }
        }
    }

    @ViewBuilder
    private func unseenDot(_ recording: Recording, size: CGFloat) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .opacity(unseen(recording) ? 1 : 0)
    }

    private func unseen(_ recording: Recording) -> Bool {
        recording.resumeMs == nil && recording.watchedAt == nil
    }

    private func cardMeta(_ recording: Recording) -> String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        return "\(recording.serviceName) · \(Wording.time(start))"
    }

    /// 上の大きな情報の事実の行 (局 · 日付 時刻 · 長さ)
    private func metaLine(_ recording: Recording) -> String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let length = Wording.duration(Wording.effectiveDurationMs(of: model.entry(for: recording)))
        return "\(recording.serviceName) · \(Wording.dateShort(start)) \(Wording.time(start)) · \(length)"
    }

    // MARK: - 決まり

    private var hero: Recording? {
        model.visible.first { $0.id == focused } ?? model.visible.first
    }

    /// 絵の右上の暖かい光
    private var background: some View {
        ZStack {
            TVTheme.background
            RadialGradient(
                colors: [Color(red: 0.91, green: 0.71, blue: 0.56).opacity(0.45), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 900
            )
            .blur(radius: 40)
        }
        .ignoresSafeArea()
    }

    private func open(_ recording: Recording, from: Double?) {
        guard let server = app.server else { return }
        let session = RecordingSession(
            baseURL: server.url,
            token: server.token,
            recording: recording,
            playable: Playable.formats,
            app: app,
            kind: recording.recording ? .chase : .recording,
            startFrom: from
        )
        cover = .watch(TVWatchRequest(session: session))
    }

    private func delete(_ recording: Recording) async {
        if let message = await model.delete(recording) {
            alertMessage = message
        }
    }
}

/// 録画のカード (TV-Recordings)。検索のカードも同じ部品を使う (D31)。
/// 押せる面 (Button) とフォーカスは呼び手が持つ。
struct TVRecordingCard: View {
    let title: String
    let meta: String
    let poster: String?
    let unseen: Bool
    let recording: Bool
    let baseURL: URL?
    let token: String?
    /// 観られない録画は押せない見た目にする
    var playable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TVPosterImage(
                    poster: poster,
                    baseURL: baseURL,
                    token: token,
                    width: 510,
                    height: 287
                )
                if recording {
                    Text("● 録画中")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(.red, in: RoundedRectangle(cornerRadius: 8))
                        .padding(14)
                }
            }
            .frame(width: 510, height: 287)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            // 浮き上がりと光沢は tvOS の標準の効果に任せる (純正の TV アプリの並び)。札も絵と一緒に動かす
            .hoverEffect(.highlight)

            // 番組名とメタ情報は絵の下 (純正の TV アプリの並べ方)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .opacity(unseen ? 1 : 0)
                Text(title)
                    .font(DenpaFont.font(size: 34))
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text(meta)
                .font(.system(size: 26))
                .foregroundStyle(TVTheme.muted)
        }
        .frame(width: 510, alignment: .leading)
        .opacity(playable ? 1 : 0.45)
    }
}

/// 観る画面に渡す 1 本 (tvOS)。
struct TVWatchRequest: Identifiable {
    let id = UUID()
    let session: RecordingSession
}

/// カードのサムネイル。`poster` が無い・取れないときは面の色。
struct TVPosterImage: View {
    let poster: String?
    let baseURL: URL?
    let token: String?
    let width: CGFloat
    let height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: poster) { await load() }
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
        image = loaded
    }
}

/// denpa に接続できなかったとき (TV-Recordings)。絵には無いので、字を大きくして中央に置く
struct TVOfflineView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(TVTheme.muted)
            Text("denpa に接続できません")
                .font(.system(size: 40, weight: .bold))
                .padding(.top, 8)
            Text("Wi-Fi などの接続状況を確認してください。")
                .font(.system(size: 28))
                .foregroundStyle(TVTheme.muted)
            Button("再試行", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
