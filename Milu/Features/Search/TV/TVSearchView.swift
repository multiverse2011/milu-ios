import SwiftUI

/// Apple TV の検索 (TV-Search・3.5・D31)。欄とキーボードは tvOS の標準の `.searchable`。
/// 結果は「録画」をカードの列、「これからの放送」を横に並ぶ札で出す。
struct TVSearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SearchModel()
    /// 番組の詳細だけを持つ。再生はモデルの `openRequest` を見る
    @State private var program: GuideProgramItem?

    /// 再生と番組の詳細は 1 つの cover で切り替える (TVRecordingsTabView と同じ決まり)
    private enum Cover: Identifiable {
        case watch(SearchModel.OpenRequest)
        case program(GuideProgramItem)

        var id: String {
            switch self {
            case .watch(let request): "watch-\(request.id)"
            case .program(let item): "program-\(item.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TVTheme.background
                    .ignoresSafeArea()
                content
            }
            .searchable(text: query, prompt: Text("番組・録画を検索"))
        }
        .task { await model.start(app) }
        .onDisappear { model.stop() }
        .alert(
            model.openError ?? "",
            isPresented: Binding(
                get: { model.openError != nil },
                set: { if !$0 { model.clearOpenError() } }
            )
        ) {
            Button("OK", role: .cancel) { model.clearOpenError() }
        }
        .fullScreenCover(item: cover) { cover in
            switch cover {
            case .watch(let request):
                TVRecordingPlayerView(session: request.session) {
                    model.closeOpen()
                    Task { await model.refresh() }
                }
            case .program(let item):
                TVProgramView(item: item, model: model, onClose: { program = nil })
                    .background(TVTheme.background)
            }
        }
    }

    private var query: Binding<String> {
        Binding(get: { model.query }, set: { model.setQuery($0) })
    }

    /// モデルが検証して置いたセッションと、画面が選んだ番組の詳細を 1 つの cover にする
    private var cover: Binding<Cover?> {
        Binding(
            get: {
                if let request = model.openRequest { return .watch(request) }
                if let program { return .program(program) }
                return nil
            },
            set: { value in
                switch value {
                case .program(let item): program = item
                case .watch, .none:
                    program = nil
                    model.closeOpen()
                }
            }
        )
    }

    // MARK: - 中身

    @ViewBuilder
    private var content: some View {
        if model.trimmedQuery.isEmpty {
            EmptyView()
        } else if model.load == .offline {
            TVOfflineView {
                model.retry()
            }
        } else if let results = model.results, !results.isEmpty {
            resultsView(results)
        } else if model.load == .empty {
            none
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var none: some View {
        ContentUnavailableView {
            Label("「\(model.trimmedQuery)」に一致するものはありません", systemImage: "magnifyingglass")
        } description: {
            Text("録画と、番組表のこれからの放送から探しています。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultsView(_ results: SearchResponse) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                if !results.recordings.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        heading("録画")
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 48) {
                                ForEach(results.recordings.rows) { recording in
                                    recordingCard(recording)
                                }
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 4)
                        }
                        .scrollClipDisabled()
                        moreNote(results.recordings.more)
                    }
                }
                if !results.programs.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        heading("これからの放送")
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 24) {
                                ForEach(results.programs.rows) { program in
                                    programCard(program)
                                }
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 4)
                        }
                        .scrollClipDisabled()
                        moreNote(results.programs.more)
                    }
                }
            }
            // 左の余白は TabView(.sidebarAdaptable) の安全領域に任せる (録画の一覧と同じ)
            .padding(.trailing, 40)
            // 上の余白は小さくする。結果の先頭へフォーカスが移ると tvOS が結果を上へ送り、
            // 検索欄が左上の「検索」の札に潜り込む (カードの題名を絵の下へ移して縦に伸びたため)
            // shortcut: 余白はカードの高さで測った値、カードの高さか上の構成を変えたら測り直す
            .padding(.top, 8)
            .padding(.bottom, 60)
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Color(white: 0.92).opacity(0.86))
    }

    private func moreNote(_ more: Bool) -> some View {
        Group {
            if more {
                Text("ほかにもあります。言葉を足すと絞り込めます。")
                    .font(.callout)
                    .foregroundStyle(TVTheme.muted)
            }
        }
    }

    private func recordingCard(_ recording: SearchRecording) -> some View {
        Button {
            Task { await model.openRecording(id: recording.id) }
        } label: {
            TVRecordingCard(
                title: recording.name,
                meta: SearchModel.tvRecordingSubtitle(recording),
                poster: recording.posterPath,
                unseen: false,
                recording: recording.isRecording,
                baseURL: app.server?.url,
                token: app.server?.token,
                playable: recording.playable
            )
        }
        .buttonStyle(.borderless)
        .disabled(!recording.playable)
        .accessibilityHint(Text(recording.playable ? "" : String(localized: "再生できません")))
    }

    private func programCard(_ program: SearchProgram) -> some View {
        let text = SearchModel.programRowText(program, now: Date())
        return Button {
            self.program = model.programItem(program)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(text.day) \(text.time) · \(program.serviceName)")
                    .font(.callout)
                    .foregroundStyle(TVTheme.muted)
                Text(program.name)
                    .font(DenpaFont.font(.body))
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let state = text.state {
                    Text(state.text())
                        .font(.callout.bold())
                        .foregroundStyle(state == .onAir ? TVTheme.record : Color.accentColor)
                }
            }
            .padding(22)
            .frame(width: 520, alignment: .leading)
        }
        .buttonStyle(.card)
    }

}
