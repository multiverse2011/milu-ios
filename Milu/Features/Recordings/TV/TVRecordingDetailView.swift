import SwiftUI

/// tvOS の録画の詳細 (TV-RecordingDetail)。カードの決定の長押しで出す。
/// 続きから再生・最初から・削除・閉じる。削除は確認を通す (3.5・3.5.3)。
struct TVRecordingDetailView: View {
    let recording: Recording
    /// 続きから再生の位置 (ms)。再生の画面から開いたときは、いまの位置を渡す
    var resumeMs: Int64? = nil
    let onPlay: (Double?) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    /// 本文の下の余白。案内の判定からも同じ値を使う (余白だけが画面外のときは案内を出さない)
    private static let bottomPadding: CGFloat = 120

    @Environment(AppModel.self) private var app

    @State private var detail: RecordingDetail?
    @State private var format: OfferCodec?
    @State private var confirmDelete = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    title
                    if let resumeText {
                        progress(resumeText)
                    }
                    facts
                    buttons
                    bodyText
                }
                .frame(width: 1300, alignment: .leading)
                .padding(.leading, 140)
                .padding(.top, 110)
                .padding(.bottom, Self.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .tvContinueHint(bottomPadding: Self.bottomPadding)
        }
        .onExitCommand(perform: onClose)
        .task { await load() }
        .alert(recording.title, isPresented: $confirmDelete) {
            Button("削除", role: .destructive, action: onDelete)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この録画を denpa から削除します。")
        }
    }

    /// 画面案の `linear-gradient(180deg, #9cc8ec, #2e4a5e)` を全画面に薄くかけた地
    private var background: some View {
        ZStack {
            TVTheme.background
            LinearGradient(
                colors: [
                    Color(red: 0.61, green: 0.78, blue: 0.93),
                    Color(red: 0.18, green: 0.29, blue: 0.37),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.22)
            .blur(radius: 40)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 16) {
            TVChannelLogo(name: recording.serviceName)
            Text("\(recording.serviceName) · \(dateRange) · \(length)")
                .font(.system(size: 28))
                .foregroundStyle(TVTheme.body)
        }
    }

    private var title: some View {
        Text(recording.title)
            .font(DenpaFont.font(size: 60))
            .fontWeight(.bold)
            .lineLimit(3)
            .padding(.top, 16)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 20) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * watchedFraction)
                }
            }
            .frame(width: 520, height: 8)
            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(TVTheme.muted)
        }
        .padding(.top, 22)
    }

    /// 事実の行 (D23: 録画ではジャンルを出さない。形式だけを札にする)
    private var facts: some View {
        HStack(spacing: 12) {
            if let format {
                chip(PlaybackRules.codecName(format))
            }
        }
        .padding(.top, 20)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24))
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)。
    /// 優先度は 主要 = prominent、破壊的 = role、ほか = bordered で表す
    private var buttons: some View {
        HStack(spacing: 20) {
            if recording.recording {
                Button("再生") { onPlay(nil) }
                    .buttonStyle(.borderedProminent)
            } else if let startResumeMs {
                Button("続きから再生 (\(Wording.position(startResumeMs)))") {
                    onPlay(Double(startResumeMs) / 1000)
                }
                .buttonStyle(.borderedProminent)
                Button("最初から") { onPlay(0) }
                    .buttonStyle(.bordered)
                deleteButton
            } else {
                Button("再生") { onPlay(nil) }
                    .buttonStyle(.borderedProminent)
                deleteButton
            }
            Button("閉じる", action: onClose)
                .buttonStyle(.bordered)
        }
        .font(.system(size: 28, weight: .semibold))
        .controlSize(.large)
        .focusSection()
        .padding(.top, 36)
    }

    private var deleteButton: some View {
        Button("削除", role: .destructive) { confirmDelete = true }
            .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var bodyText: some View {
        if let detail {
            if !detail.description.isEmpty {
                TVReadingText(
                    text: detail.description, font: DenpaFont.font(size: 30),
                    lineSpacing: 10, scalesWithTextSize: true
                )
                    .foregroundStyle(TVTheme.body)
                    .padding(.top, 44)
            }
            ForEach(GuideText.extendedItems(detail.extended), id: \.heading) { item in
                Text(GuideText.extendedHeading(item.heading))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(TVTheme.body)
                    .padding(.top, 28)
                TVReadingText(
                    text: item.body, font: DenpaFont.font(size: 30),
                    lineSpacing: 10, scalesWithTextSize: true
                )
                    .foregroundStyle(TVTheme.body)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - 決まり

    /// 続きから再生の位置。再生の画面から開いたときは、開いた瞬間の位置 (3.3「観た位置」)。
    /// 1 秒未満は「再生」に倒す
    private var startResumeMs: Int64? {
        RecordingRules.detailResumeMs(override: resumeMs, saved: recording.resumeMs)
    }

    private var watchedFraction: Double {
        RecordingRules.watchedFraction(resumeMs: startResumeMs, durationMs: recording.durationMs)
    }

    private var resumeText: String? {
        guard let startResumeMs, let durationMs = recording.durationMs else { return nil }
        let rem = Wording.remaining(max(0, durationMs - startResumeMs), kind: .left)
        return String(localized: "\(Wording.position(startResumeMs))まで視聴 · \(rem)")
    }

    private var length: String {
        Wording.duration(recording.durationMs ?? max(0, recording.endAt - recording.startAt))
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(recording.endAt) / 1000)
        return "\(Wording.dateShort(start)) \(Wording.timeRange(from: start, to: end, separator: .recording))"
    }

    private func load() async {
        if let data = try? await app.get("api/recordings/\(recording.id)/detail"),
           let loaded = try? JSONDecoder().decode(RecordingDetail.self, from: data) {
            detail = loaded
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
