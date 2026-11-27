import SwiftUI

/// 録画の画面の中で探した結果 (3.5・D32・iPhone-D-Results)。`api/search` の `recordings` だけを出す。
/// 開く・閉じたあとの読み直し・失敗の alert は RecordingsView が持つ。
struct RecordingsSearchResults: View {
    @Environment(AppModel.self) private var app
    let model: SearchModel
    /// 横長の iPad はカード、それ以外は行 (録画の一覧と同じ使い分け)
    let wide: Bool

    var body: some View {
        if model.load == .offline {
            OfflineView(host: app.address) {
                model.retry()
            }
        } else if let recordings = model.recordingResults, !recordings.rows.isEmpty {
            if wide {
                grid(recordings)
            } else {
                list(recordings)
            }
        } else if model.recordingResults != nil {
            ContentUnavailableView(
                "「\(model.trimmedQuery)」に一致する録画はありません",
                systemImage: "magnifyingglass"
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ recordings: SearchSection<SearchRecording>) -> some View {
        List {
            Section {
                ForEach(recordings.rows) { recording in
                    button(recording) {
                        RecordingRow(
                            title: recording.name,
                            subtitle: SearchModel.recordingSubtitle(recording),
                            third: SearchModel.recordingThird(recording),
                            poster: recording.posterPath,
                            watchedFraction: nil,
                            unseen: false,
                            baseURL: app.server?.url,
                            token: app.server?.token,
                            playable: recording.playable
                        )
                    }
                    .recordingRowLayout(isLast: recording.id == recordings.rows.last?.id)
                }
            } footer: {
                moreNote(recordings.more)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }

    private func grid(_ recordings: SearchSection<SearchRecording>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 16)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(recordings.rows) { recording in
                        button(recording) {
                            RecordingCard(
                                title: recording.name,
                                subtitle: SearchModel.recordingSubtitle(recording),
                                poster: recording.posterPath,
                                watchedFraction: nil,
                                unseen: false,
                                recording: recording.isRecording,
                                baseURL: app.server?.url,
                                token: app.server?.token,
                                playable: recording.playable
                            )
                        }
                    }
                }
                moreNote(recordings.more)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable { await model.refresh() }
    }

    /// 観られる録画だけ押せる。検索の行は一覧の全部を返さないので、モデルが一覧から本物の行を探して開く
    @ViewBuilder
    private func button(_ recording: SearchRecording, @ViewBuilder label: () -> some View) -> some View {
        if recording.playable {
            Button {
                Task { await model.openRecording(id: recording.id) }
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else {
            label()
        }
    }

    /// `more` のとき (3.5)
    @ViewBuilder
    private func moreNote(_ more: Bool) -> some View {
        if more {
            Text("ほかにもあります。言葉を足すと絞り込めます。")
                .scaledFont(13)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}
