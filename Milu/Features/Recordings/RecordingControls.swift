import SwiftUI

/// 録画のシークバー (3.5・milu.css の `.scrub`)。つまんでいる間は位置だけを替える。
struct RecordingScrubber: View {
    let position: Double
    let duration: Double
    /// 追っかけで録れている所 (秒)。無ければ録画
    var recorded: Double? = nil
    /// つまんで動かせる上限 (秒)。追っかけは録れている所まで
    var limit: Double? = nil
    let chapters: [Chapter]
    @Binding var preview: Double?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let shown = preview ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            let recordedFraction = recorded.flatMap { duration > 0 ? min(1, max(0, $0 / duration)) : nil }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                if let recordedFraction {
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: width * recordedFraction)
                }
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    if chapter.title == "CM", duration > 0 {
                        let start = min(1, max(0, chapter.start / duration))
                        let end = min(1, max(0, chapter.end / duration))
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: max(0, (end - start) * width))
                            .offset(x: start * width)
                    }
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: width * fraction - 7)
            }
            .frame(height: 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let maxValue = min(duration, limit ?? duration)
                        preview = min(max(0, value.location.x / width) * duration, maxValue)
                    }
                    .onEnded { _ in
                        if let target = preview {
                            onSeek(target)
                        }
                        preview = nil
                    }
            )
        }
        .frame(height: 24)
    }
}

/// 追っかけの「● 録画中」の札 (3.5・iPhone-Chase)。
struct RecordingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Text("録画中")
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// 「字幕と音声」のメニュー (3.5・iPhone-CaptionMenu)。どちらも無ければボタンを出さない。
struct RecordingCaptionsMenu: View {
    let session: RecordingSession
    var size: CGFloat = 36
    let onInteraction: () -> Void

    var body: some View {
        Menu {
            Group {
            if session.hasCaptions {
                Section("字幕") {
                    Button {
                        session.setCaptionsOn(true)
                    } label: {
                        HStack {
                            if session.captionsOn { Image(systemName: "checkmark") }
                            Text("オン")
                        }
                    }
                    Button {
                        session.setCaptionsOn(false)
                    } label: {
                        HStack {
                            if !session.captionsOn { Image(systemName: "checkmark") }
                            Text("オフ")
                        }
                    }
                }
            }
            if session.audioTracks.count > 1 {
                Section("音声") {
                    ForEach(session.audioTracks, id: \.id) { track in
                        Button {
                            session.selectAudio(track)
                        } label: {
                            HStack {
                                if track.id == session.selectedAudio?.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(track.label)
                            }
                        }
                    }
                }
            }
            }
            .onAppear { onInteraction() }
        } label: {
            GlassCircleLabel(systemName: "captions.bubble", size: size)
        }
        .accessibilityLabel("字幕と音声")
    }
}

/// 「その他」のメニュー (3.5・iPhone-PlayerMenu)。
struct RecordingMoreMenu: View {
    let session: RecordingSession
    /// 追っかけでは CM 飛ばしと削除を出さない (3.5)
    var isChase = false
    var size: CGFloat = 36
    let onInteraction: () -> Void
    let onDetail: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Group {
            Menu("再生速度") {
                ForEach(RecordingRules.speeds, id: \.self) { value in
                    Button {
                        session.setSpeed(value)
                    } label: {
                        HStack {
                            if session.speed == value { Image(systemName: "checkmark") }
                            Text(RecordingRules.speedName(value))
                        }
                    }
                }
            }
            if session.qualityItems.count > 1 || !session.rungItems.isEmpty {
                Menu("画質") {
                    if session.qualityItems.count > 1 {
                        ForEach(session.qualityItems, id: \.title) { item in
                            Button {
                                session.selectQuality(item.codec)
                            } label: {
                                HStack {
                                    if item.codec == session.selectedQuality {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(item.title)
                                    if item.codec == nil, let codec = session.currentCodec {
                                        Spacer()
                                        Text(PlaybackRules.codecName(codec))
                                    }
                                }
                            }
                        }
                    }
                    if !session.rungItems.isEmpty {
                        Section("解像度") {
                            ForEach(session.rungItems, id: \.rung) { item in
                                Button {
                                    session.selectRung(item.rung)
                                } label: {
                                    HStack {
                                        if item.rung == session.selectedRung {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(item.title)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !isChase {
                Button {
                    session.setCmSkip(!session.cmSkipEnabled)
                } label: {
                    HStack {
                        Text("CMをスキップ")
                        if session.cmSkipEnabled {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !isChase {
                Divider()
                Button("詳細", action: onDetail)
                Button("削除", role: .destructive, action: onDelete)
            }
            }
            .onAppear { onInteraction() }
        } label: {
            GlassCircleLabel(systemName: "ellipsis", size: size)
        }
        .accessibilityLabel(String(localized: "その他 (メニュー)", defaultValue: "その他"))
    }
}

/// 最後まで観た (3.5・iPhone-PlayerEnd)。
struct RecordingEndOverlay: View {
    let recording: Recording
    let onClose: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 8) {
                Text("再生が終了しました")
                    .scaledFont(14)
                    .foregroundStyle(.white.opacity(0.75))
                Text(recording.title)
                    .font(DenpaFont.font(size: 22))
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text("\(recording.serviceName) · \(dateRange)")
                    .scaledFont(13)
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 12) {
                    Button("一覧に戻る", action: onClose)
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(width: 150)
                    Button("削除", action: onDelete)
                        .buttonStyle(SecondaryButtonStyle(height: 50, destructive: true))
                        .frame(width: 100)
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 40)
        }
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(recording.endAt) / 1000)
        return "\(Wording.dateShort(start)) \(Wording.timeRange(from: start, to: end, separator: .recording))"
    }
}

/// 止まった (3.5・iPhone-PlayerError)。題と理由は 3.3 の表のもの。
struct RecordingErrorOverlay: View {
    let stop: RecordingSession.Stop
    let onRetry: () -> Void
    let onClose: () -> Void

    private var title: String {
        switch stop.reason {
        case .noPlayableFormat: String(localized: "再生できる形式がありません")
        case .noVideo: String(localized: "この録画は再生できません")
        case .serverBusy: String(localized: "サーバーが混み合っています")
        case .emptyStream: String(localized: "映像を受信できませんでした")
        case .refused: String(localized: "再生できません")
        }
    }

    private var message: String {
        switch stop.reason {
        case .noPlayableFormat:
            String(localized: "この \(DeviceName.name) に対応した映像形式がありません。")
        case .noVideo:
            String(localized: "映像のない録画は再生できません。")
        case .refused(let message):
            message
        default:
            ""
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .scaledFont(44, weight: .light)
                    .foregroundStyle(.orange)
                Text(title)
                    .scaledFont(20, weight: .bold)
                    .multilineTextAlignment(.center)
                if !message.isEmpty {
                    Text(message)
                        .scaledFont(14)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    if stop.retry {
                        Button("再試行", action: onRetry)
                            .buttonStyle(SecondaryButtonStyle(height: 44))
                            .frame(width: 130)
                    }
                    Button("閉じる", action: onClose)
                        .buttonStyle(SecondaryButtonStyle(height: 44))
                        .frame(width: 110)
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 40)
        }
    }
}
