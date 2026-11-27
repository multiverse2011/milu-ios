import SwiftUI

/// ライブの番組の詳細 (TV-LiveDetail)。決定の長押しで開く。
struct TVLiveDetailView: View {
    let service: Service
    let baseURL: URL?
    let token: String?
    let session: PlaybackSession?
    let detail: ProgramDetail?
    /// いまの番組を録る予定か録っている最中か
    let recording: Bool
    @FocusState.Binding var focus: TVLiveFocus?
    let onToggleRecord: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            TVTheme.scrim.opacity(0.82)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView(.vertical) {
                    content(now: context.date)
                        .padding(.horizontal, 140)
                        .padding(.top, 110)
                        .padding(.bottom, 120)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    // ボタンより下の説明へ下キーで送るための置き場。フォーカスが来ると ScrollView がそこまで送る
                    Color.clear
                        .frame(height: 1)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focus, equals: .detailContinue)
                }
            }
            // 画面案の下端の案内
            Text("▼ 下キーで続き")
                .font(.callout)
                .foregroundStyle(TVTheme.muted)
                .padding(.bottom, 50)
        }
        .defaultFocus($focus, .detailRecord, priority: .userInitiated)
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                TVServiceLogo(service: service, baseURL: baseURL, token: token)
                Text(headerText)
                    .font(.body)
                    .foregroundStyle(TVTheme.body)
            }
            Text(service.now?.title ?? "")
                .font(DenpaFont.font(.title))
                .fontWeight(.bold)
                .lineSpacing(6)
                .padding(.top, 16)
            HStack(spacing: 20) {
                TVProgressBar(value: TVLiveText.progress(service.now, now: now), height: 8)
                    .frame(width: 520)
                Text(TVLiveText.remaining(service.now, now: now))
                    .font(.callout)
                    .foregroundStyle(TVTheme.muted)
            }
            .padding(.top, 22)
            chips.padding(.top, 20)
            buttons.padding(.top, 36)
            if let description = detail?.description, !description.isEmpty {
                Text(description)
                    .font(DenpaFont.font(.body))
                    .lineSpacing(12)
                    .foregroundStyle(TVTheme.body)
                    .frame(maxWidth: 1340, alignment: .leading)
                    .padding(.top, 44)
            }
            ForEach(Array(extendedItems.enumerated()), id: \.offset) { _, item in
                Text(GuideText.extendedHeading(item.heading))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TVTheme.body)
                    .padding(.top, 28)
                Text(item.body)
                    .font(DenpaFont.font(.body))
                    .lineSpacing(12)
                    .foregroundStyle(TVTheme.body)
                    .frame(maxWidth: 1340, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    /// 「みなとテレビ · 15:00–15:30 · 30 分」。番組の詳細は「–」(3.5.3、TV-Program と同じ)
    private var headerText: String {
        guard let program = service.now else { return service.name }
        let start = Date(timeIntervalSince1970: Double(program.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(program.endAt) / 1000)
        let range = Wording.timeRange(from: start, to: end, separator: .live)
        return "\(service.name) · \(range) · \(Wording.duration(program.endAt - program.startAt))"
    }

    private var chips: some View {
        HStack(spacing: 12) {
            ForEach(chipTitles, id: \.self) { title in
                Text(title)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// ジャンル・形式・音声 (画面案 TV-LiveDetail)
    private var chipTitles: [String] {
        var titles: [String] = []
        if let label = GenreName.label(details: (detail?.genreDetail ?? []).map { (lv1: $0.lv1, lv2: $0.lv2) }) {
            titles.append(label)
        }
        if let codec = session?.currentCodec {
            titles.append(PlaybackRules.codecName(codec))
        }
        if let audio = session?.selectedAudio?.label, !audio.isEmpty {
            titles.append(audio)
        }
        return titles
    }

    /// 外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)。
    /// 録画中は字と録画の赤で示す。状態でスタイルを切り替えると押した直後に
    /// フォーカスが外れるため、bordered の 1 つに固定する
    private var buttons: some View {
        HStack(spacing: 20) {
            Button(recording ? String(localized: "● 録画中") : String(localized: "● 録画")) {
                onToggleRecord()
            }
                .buttonStyle(.bordered)
                .tint(recording ? TVTheme.record : Color.accentColor)
                .focused($focus, equals: .detailRecord)
            Button("閉じる") { onClose() }
                .buttonStyle(.bordered)
                .focused($focus, equals: .detailClose)
        }
        .controlSize(.large)
        .focusSection()
    }

    /// `extended` の項目のうち、説明の段落と重なる「番組内容」を除いたもの (3.5.3 の並び)
    private var extendedItems: [(heading: String, body: String)] {
        GuideText.extendedItems(detail?.extended ?? [:])
            .filter { $0.heading != "番組内容" }
    }
}
