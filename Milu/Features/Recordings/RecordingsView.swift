import SwiftUI

/// 録画のタブ (3.5・iPhone-Recordings)。一覧・絞り込み・削除・観る画面・録画の中の検索 (D32)。
struct RecordingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = RecordingsModel()
    @State private var watch: WatchRequest?
    @State private var detail: Recording?
    @State private var pendingDelete: Recording?
    @State private var alertMessage: String?
    @State private var search = SearchModel()
    /// 向きの判定に使うウィンドウの大きさ。表示領域の大きさは再評価のきっかけにだけ使う
    @State private var windowSize = WindowShape.windowSize

    var body: some View {
        NavigationStack {
            content
                // ウィンドウの大きさは観測できないので、回転と Split View の出入りは
                // 表示領域の変化をきっかけに読み直す。キーボードで縮んでも値は変わらない
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                    let next = WindowShape.windowSize
                    if next != windowSize {
                        windowSize = next
                    }
                }
                .navigationTitle("録画")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        filterMenu
                    }
                }
                .searchable(
                    text: Binding(get: { search.query }, set: { search.setQuery($0) }),
                    prompt: Text("録画を検索")
                )
        }
        .task {
            await model.start(app)
        }
        .task {
            await search.start(app)
        }
        .onDisappear {
            model.stop()
            search.stop()
        }
        .sheet(item: $detail) { recording in
            RecordingDetailView(
                recording: recording,
                baseURL: app.server?.url,
                token: app.server?.token,
                logo: model.service(for: recording.serviceId),
                onPlay: { from in
                    detail = nil
                    open(recording, from: from)
                },
                onDelete: { recording in
                    // 詳細の確認で「削除」を押した。ここでもう一度聞かない
                    detail = nil
                    Task {
                        if let message = await model.delete(recording) {
                            alertMessage = message
                        }
                    }
                }
            )
        }
        .fullScreenCover(item: $watch) { request in
            RecordingWatchView(session: request.session) { _ in
                watch = nil
                Task { await model.refreshFromEvents() }
            }
        }
        // 検索の行から開く録画。モデルが一覧から本物の行を探して置く
        .fullScreenCover(item: Binding(get: { search.openRequest }, set: { if $0 == nil { search.closeOpen() } })) { request in
            RecordingWatchView(session: request.session) { deletedID in
                // 削除した行は読み直しを待たずに外す
                search.closeOpen(deletedID: deletedID)
                // 検索の読み直しは一覧の読み直しを待たない。削除で閉じたときは
                // 削除より前に送った GET に合流しない
                Task { await model.refreshFromEvents() }
                Task { await search.refresh(joiningInFlight: deletedID == nil) }
            }
        }
        .alert(
            search.openError ?? "",
            isPresented: Binding(
                get: { search.openError != nil },
                set: { if !$0 { search.clearOpenError() } }
            )
        ) {
            Button("OK", role: .cancel) { search.clearOpenError() }
        }
        // 画面案は confirmationDialog だが、iOS 27 のタブの中では浮いているタブの帯に
        // 「キャンセル」が隠れたため、確実に出る alert にした
        .alert(
            pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { recording in
            Button("削除", role: .destructive) {
                pendingDelete = nil
                Task {
                    if let message = await model.delete(recording) {
                        alertMessage = message
                    }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("この録画を denpa から削除します。")
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

    @ViewBuilder
    private var content: some View {
        // キーボードで表示領域が縮んでも変わらないよう、ウィンドウの大きさで決める (issue #65)
        let wide = WindowShape.isWide(
            isPad: DeviceName.isPad,
            isRegularWidth: horizontalSizeClass == .regular,
            window: windowSize
        )
        if !search.trimmedQuery.isEmpty {
            RecordingsSearchResults(model: search, wide: wide)
        } else if model.load == .loading, model.recordings.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.load == .offline {
            OfflineView(host: app.address) {
                Task { await model.reload() }
            }
        } else if model.load == .empty {
            ContentUnavailableView(
                "録画がありません",
                systemImage: "play.rectangle",
                description: Text("録画した番組がここに表示されます。")
            )
        } else if model.visible.isEmpty, model.filter == .unseen {
            ContentUnavailableView(
                "未視聴の録画はありません",
                systemImage: "checkmark.circle",
                description: Text("再生を始めた録画と視聴済みの録画は、ここには表示されません。")
            )
        } else {
            if wide {
                grid
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.sections, id: \.date) { section in
                Section {
                    ForEach(section.entries) { recording in
                        // 画面案は日の最後の行にだけ線を引かない (iOS-Recordings の .lr.last)
                        row(recording, isLast: recording.id == section.entries.last?.id)
                    }
                } header: {
                    let heading = Wording.dateHeadingParts(section.date, reference: Date())
                    HStack(spacing: 6) {
                        Text(heading.primary)
                        Text(heading.secondary)
                            .foregroundStyle(.secondary)
                            .fontWeight(.regular)
                    }
                    .textCase(nil)
                    .scaledFont(15, weight: .semibold)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload() }
    }

    /// 横長の iPad のカードの格子 (iPad-Recordings)
    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(model.sections, id: \.date) { section in
                    let heading = Wording.dateHeadingParts(section.date, reference: Date())
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(heading.primary)
                            Text(heading.secondary)
                                .foregroundStyle(.secondary)
                                .fontWeight(.regular)
                        }
                        .scaledFont(17, weight: .semibold)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250), spacing: 16)],
                            alignment: .leading,
                            spacing: 18
                        ) {
                            ForEach(section.entries) { recording in
                                card(recording)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await model.reload() }
    }

    private func card(_ recording: Recording) -> some View {
        Button {
            open(recording, from: nil)
        } label: {
            RecordingCard(
                title: recording.title,
                subtitle: Wording.cardSubtitle(model.entry(for: recording), now: Date()),
                poster: recording.poster,
                watchedFraction: recording.posterWatchedFraction,
                unseen: unseen(recording),
                recording: recording.recording,
                baseURL: app.server?.url,
                token: app.server?.token
            )
        }
        .buttonStyle(.plain)
        .contextMenu { menuItems(recording) }
        .onAppear {
            Task { await model.loadMoreIfNeeded(current: recording) }
        }
    }

    private func unseen(_ recording: Recording) -> Bool {
        recording.resumeMs == nil && recording.watchedAt == nil
    }

    @ViewBuilder
    private func menuItems(_ recording: Recording) -> some View {
        Button {
            detail = recording
        } label: {
            Label("詳細", systemImage: "info.circle")
        }
        if !recording.recording {
            Button {
                open(recording, from: 0)
            } label: {
                Label("最初から再生", systemImage: "play")
            }
            Button(role: .destructive) {
                pendingDelete = recording
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private func row(_ recording: Recording, isLast: Bool) -> some View {
        Button {
            open(recording, from: nil)
        } label: {
            let texts = Wording.listRowSubtitles(model.entry(for: recording), now: Date())
            RecordingRow(
                title: recording.title,
                subtitle: texts.second,
                third: texts.third,
                poster: recording.poster,
                watchedFraction: recording.posterWatchedFraction,
                unseen: unseen(recording),
                baseURL: app.server?.url,
                token: app.server?.token
            )
        }
        .buttonStyle(.plain)
        .recordingRowLayout(isLast: isLast)
        .swipeActions(edge: .trailing) {
            if !recording.recording {
                Button(role: .destructive) {
                    pendingDelete = recording
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            Button {
                detail = recording
            } label: {
                Label("詳細", systemImage: "info.circle")
            }
            if !recording.recording {
                Button {
                    open(recording, from: 0)
                } label: {
                    Label("最初から再生", systemImage: "play")
                }
                Button(role: .destructive) {
                    pendingDelete = recording
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .onAppear {
            Task { await model.loadMoreIfNeeded(current: recording) }
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(RecordingsModel.Filter.allCases) { item in
                Button {
                    Task { await model.setFilter(item) }
                } label: {
                    if model.filter == item {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .scaledFont(20)
        }
        .accessibilityLabel("絞り込み (すべて・未視聴)")
        // 検索の結果には効かない (D32)
        .disabled(!search.trimmedQuery.isEmpty)
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
        watch = WatchRequest(session: session)
    }
}

/// 観る画面に渡す 1 本。
struct WatchRequest: Identifiable {
    let id = UUID()
    let session: RecordingSession
}

extension View {
    /// 一覧の行の List での置き方。検索の行も同じにする (D32)
    func recordingRowLayout(isLast: Bool) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            // 画面案の区切り線 (.lr::after): 題の字の頭 (行の頭から 7+9+12+96+12 = 136) から
            // 右端まで。日の最後の行には引かない (.lr.last)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(.secondary.opacity(0.35))
                        .frame(height: 0.5)
                        .padding(.leading, 136)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 一覧の行 (3.5・iPhone-Recordings)。検索の行も同じ部品を使う (D32)。
struct RecordingRow: View {
    let title: String
    /// 2 段目
    let subtitle: String
    /// 3 段目 (赤)。録画中だけ
    let third: String?
    let poster: String?
    let watchedFraction: Double?
    let unseen: Bool
    let baseURL: URL?
    let token: String?
    /// 観られない録画は押せない見た目にする
    var playable = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .opacity(unseen ? 1 : 0)
                .padding(.top, 12)
            RecordingPoster(
                poster: poster,
                title: title,
                baseURL: baseURL,
                token: token,
                watchedFraction: watchedFraction
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DenpaFont.font(size: 16))
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .scaledFont(13.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let third {
                    Text(third)
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.4))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(playable ? 1 : 0.45)
    }
}

/// 横長の iPad の録画のカード (iPad-Recordings)。検索のカードも同じ部品を使う (D32)。
struct RecordingCard: View {
    let title: String
    let subtitle: String
    let poster: String?
    let watchedFraction: Double?
    let unseen: Bool
    let recording: Bool
    let baseURL: URL?
    let token: String?
    /// 観られない録画は押せない見た目にする
    var playable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                RecordingPoster(
                    poster: poster,
                    title: title,
                    baseURL: baseURL,
                    token: token,
                    watchedFraction: watchedFraction,
                    width: proxy.size.width,
                    height: proxy.size.width * 9 / 16,
                    corner: 12
                )
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if recording {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("録画中")
                            .scaledFont(11.5, weight: .semibold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(unseen ? 1 : 0)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DenpaFont.font(size: 15))
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .scaledFont(13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(playable ? 1 : 0.45)
    }
}
