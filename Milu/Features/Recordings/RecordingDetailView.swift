import SwiftUI

/// 録画の詳細 (3.5・iPhone-RecordingDetail)。シートで出す。
struct RecordingDetailView: View {
    let recording: Recording
    let baseURL: URL?
    let token: String?
    let logo: Service?
    let onPlay: (Double?) -> Void
    let onDelete: (Recording) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppModel.self) private var app

    @State private var detail: RecordingDetail?
    @State private var format: OfferCodec?
    @State private var confirmDelete = false

    /// 二段組の並びは size class で分ける (Split View の狭い所では iPhone と同じ)
    private var wide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollView {
                if wide {
                    // 画面案 iPad-RecordingDetail: シート 640×700、サムネイル 224×126
                    HStack(alignment: .top, spacing: 24) {
                        RecordingPoster(
                            poster: recording.poster,
                            title: recording.title,
                            baseURL: baseURL,
                            token: token,
                            watchedFraction: recording.posterWatchedFraction,
                            width: 224,
                            height: 126,
                            corner: 12
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            facts
                            if let resume = resumeText {
                                progress(resume)
                            }
                            buttons
                            bodyText
                        }
                    }
                    .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        facts
                        if let resume = resumeText {
                            progress(resume)
                        }
                        buttons
                        bodyText
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("閉じる")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationSizing(if: wide)
        .task { await load() }
        .alert(recording.title, isPresented: $confirmDelete) {
            Button("削除", role: .destructive) {
                onDelete(recording)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この録画を denpa から削除します。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let logo {
                    ServiceLogo(service: logo, baseURL: baseURL, token: token)
                }
                Text("\(recording.serviceName) · \(dateRange)")
                    .scaledFont(14)
                    .foregroundStyle(.secondary)
            }
            Text(recording.title)
                .font(DenpaFont.font(size: wide ? 24 : 22))
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private var facts: some View {
        Text(factLine)
            .scaledFont(13.5)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private var factLine: String {
        if recording.recording {
            let left = Int64(recording.endAt - Int64(Date().timeIntervalSince1970 * 1000))
            let rem = Wording.remaining(max(0, left), kind: .ago)
            return String(localized: "● 録画中 · \(rem)")
        }
        let length = Wording.duration(recording.durationMs ?? 0)
        guard let format else { return length }
        return "\(length) · \(PlaybackRules.codecName(format))"
    }

    private var resumeText: String? {
        guard let resumeMs = recording.resumeMs, let durationMs = recording.durationMs else { return nil }
        let left = max(0, durationMs - resumeMs)
        let pos = Wording.position(resumeMs)
        let rem = Wording.remaining(left, kind: .left)
        return String(localized: "\(pos)まで視聴 · \(rem)")
    }

    private func progress(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .quaternaryLabel))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * RecordingRules.watchedFraction(
                            resumeMs: recording.resumeMs,
                            durationMs: recording.durationMs
                        ))
                }
            }
            .frame(height: 4)
            Text(text)
                .scaledFont(13)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 16)
    }

    private var buttons: some View {
        Group {
            if wide {
                // iPad は横に 3 つ
                HStack(spacing: 10) {
                    playButtons(compact: true)
                }
                .lineLimit(1)
            } else {
                VStack(spacing: 10) {
                    playButtons(compact: false)
                }
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private func playButtons(compact: Bool) -> some View {
        if recording.recording {
            Button("再生") {
                onPlay(nil)
            }
            .buttonStyle(PrimaryButtonStyle())
        } else if let resumeMs = recording.resumeMs {
            Button("続きから · \(Wording.position(resumeMs))") {
                onPlay(Double(resumeMs) / 1000)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("最初から") {
                onPlay(0)
            }
            .buttonStyle(SecondaryButtonStyle(height: compact ? 50 : 44))
            Button("削除") {
                confirmDelete = true
            }
            .buttonStyle(SecondaryButtonStyle(height: compact ? 50 : 44, destructive: true))
        } else {
            Button("再生") {
                onPlay(nil)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("削除") {
                confirmDelete = true
            }
            .buttonStyle(SecondaryButtonStyle(height: compact ? 50 : 44, destructive: true))
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        if let detail {
            if !detail.description.isEmpty {
                Text(detail.description)
                    .scaledFont(15)
                    .padding(.top, 22)
            }
            ForEach(GuideText.extendedItems(detail.extended), id: \.heading) { item in
                Text(GuideText.extendedHeading(item.heading))
                    .scaledFont(15, weight: .bold)
                    .padding(.top, 18)
                Text(item.body)
                    .scaledFont(15)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(recording.endAt) / 1000)
        return "\(Wording.dateShort(start)) \(Wording.timeRange(from: start, to: end, separator: .recording))"
    }

    private func load() async {
        if let data = try? await app.get("api/recordings/\(recording.id)/detail"),
           let detail = try? JSONDecoder().decode(RecordingDetail.self, from: data) {
            self.detail = detail
        }
        guard !recording.recording else { return }
        if let data = try? await app.get("api/recordings/\(recording.id)/playback"),
           let playback = try? JSONDecoder().decode(Playback.self, from: data),
           let offer = PlaybackRules.selectRecordingOffer(
               offers: playback.offers,
               playable: Playable.formats,
               broadcast: playback.broadcast
           ) {
            format = offer.codec
        }
    }
}

private extension View {
    /// iPad だけ画面案の大きさ (640×700) のシートにする (iPhone は今までどおり)
    @ViewBuilder
    func presentationSizing(if fixed: Bool) -> some View {
        if fixed {
            presentationSizing(FixedPresentationSizing())
        } else {
            self
        }
    }
}

private struct FixedPresentationSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 640, height: 700)
    }
}
