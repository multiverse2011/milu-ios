import SwiftUI

/// tvOS の録画・追っかけの再生 (TV-Player・TV-Chase・TV-PlayerEnd)。
/// リモコンの割り当ては design.md 3.5.1: 左右で 10 秒戻す/送る、下でシークバーと操作の列、
/// 決定で一時停止・再開、決定の長押しで番組の詳細、戻るで一覧へ。
/// 操作の列はふだん出さない。下・上で出して札へ焦点を移し、映像の面へ戻る (上・Menu) と隠す。
/// 一時停止中は自動では隠さない。止まったとき・最後まで観たときは、その画面のボタンを出す。
struct TVRecordingPlayerView: View {
    let session: RecordingSession
    let onClose: () -> Void

    @Environment(AppModel.self) private var app

    @State private var showDetail = false
    /// 詳細を開いた瞬間の位置 (ms)。開いている間、札の位置を秒で動かさない
    @State private var detailResumeMs: Int64?
    @State private var confirmDelete = false
    @State private var alertMessage: String?
    @State private var closing = false
    @State private var controlsVisible = false
    @State private var hideTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @FocusState private var surfaceFocused: Bool
    @FocusState private var control: Control?

    private enum Control: Hashable {
        case playPause, nextChapter, latest, speed, quality, rung, captions, cmSkip, audio
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                video(height: proxy.size.height)
                if controlsVisible, session.stop == nil, !session.finished {
                    shade(height: 520, opacity: 0.78)
                    controls
                }
                if session.showReconnect {
                    reconnect
                }
                if let stop = session.stop {
                    errorOverlay(stop)
                }
                if session.finished {
                    endOverlay
                }
            }
        }
        .onPlayPauseCommand {
            session.togglePlayCommand()
        }
        .onExitCommand {
            // 戻る: 出ているものを閉じる。何も出ていなければ再生の画面を閉じる (3.5.1)
            if controlsVisible, session.stop == nil, !session.finished {
                hideControls()
            } else {
                close()
            }
        }
        .task { await session.start() }
        // 開いた直後の焦点は映像の面に置く (純正と同じ)。開いた 1 回だけ当てる。
        // defaultFocus は焦点が外れたとき (操作の列やメニューへ移ったとき) にも既定を当て直そうとし、
        // 面が操作の列を出している間も focusable なままなので、札やメニューから焦点を奪う。
        // onAppear は焦点の仕組みより先に走ることがあるので、1 度譲ってから当てる
        .task {
            await Task.yield()
            surfaceFocused = true
        }
        .onDisappear {
            hideTask?.cancel()
            focusTask?.cancel()
            Task { await session.close() }
        }
        // 札から映像の面へ戻ったら、再生中は操作の列を隠す (詳細の sheet を閉じたときも同じ)
        .onChange(of: surfaceFocused) { _, focused in
            guard focused, controlsVisible, session.isPlaying, session.stop == nil, !session.finished else { return }
            hideControls()
        }
        // 一時停止したら操作の列を出したままにする (再生が始まったらまた隠してよい)
        .onChange(of: session.isPlaying) { _, playing in
            if playing {
                scheduleHide()
            } else if session.stop == nil, !session.finished {
                showControls()
            }
        }
        .sheet(isPresented: $showDetail) {
            TVRecordingDetailView(
                recording: session.recording,
                resumeMs: detailResumeMs,
                onPlay: { from in
                    showDetail = false
                    playDetail(from: from)
                },
                onDelete: {
                    // 詳細の確認で「削除」を押した。ここでもう一度聞かない
                    showDetail = false
                    Task { await deleteRecording() }
                },
                onClose: { showDetail = false }
            )
            .background(TVTheme.background)
        }
        .alert(session.recording.title, isPresented: $confirmDelete) {
            Button("削除", role: .destructive) {
                Task { await deleteRecording() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
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

    // MARK: - 映像とリモコン

    private func video(height: CGFloat) -> some View {
        ZStack {
            VideoSurface(
                layer: session.displayLayer,
                overlay: session.finished ? nil : captionImage,
                // 操作の列を出している間は、字幕をその上まで持ち上げる (3.5.2)
                overlayOffset: controlsVisible ? -captionLift(height: height) : 0
            )
            // 映像の面。ここにフォーカスがある間、左右で 10 秒、決定で一時停止・長押しで詳細。
            // 止まった・最後まで観たときはボタンへフォーカスを渡す
            Color.clear
                .contentShape(Rectangle())
                .focusable(session.stop == nil && !session.finished)
                .focusEffectDisabled()
                .focused($surfaceFocused)
                .onMoveCommand { direction in
                    switch direction {
                    case .left:
                        session.skip(by: -10)
                        reveal()
                    case .right:
                        session.skip(by: 10)
                        reveal()
                    case .down, .up:
                        showControls(focusFirstPill: true)
                    default:
                        break
                    }
                }
                // 2 つを `exclusively(before:)` で組むと実機の決定で一時停止しなかった。
                // 前の LongPressGesture が押下を先に取り、0.6 秒に届かない短い押下が Tap に渡らないためと見ている (推測)。
                // ライブの映像の面と同じく、2 つを別々に受ける
                .onTapGesture {
                    // 長押しで詳細を開いたあとに離した決定は受け止める
                    guard !showDetail else { return }
                    session.togglePlayCommand()
                }
                .onLongPressGesture(minimumDuration: 0.6) {
                    openDetail()
                }
        }
        .ignoresSafeArea()
    }

    /// 絵の下の地。映像の下だけを滑らかに暗くする (画面案 TV-Player は下 520px)
    private func shade(height: CGFloat, opacity: Double) -> some View {
        LinearGradient(
            colors: [.clear, .black.opacity(opacity)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// 字幕を持ち上げる量。操作の列 (下から約 340pt) の上へ、字幕の面の字の下端が来るようにする
    private func captionLift(height: CGFloat) -> CGFloat {
        guard height > 0, let page = session.captionPage else { return 0 }
        let span = CaptionLayout.inkSpan(page: page)
        let top = height - Self.controlsHeight
        return max(0, span.bottom * height - top + 16)
    }

    /// 操作の列の高さの見積り (題・シークバー・時刻・札・下の余白)
    private static let controlsHeight: CGFloat = 340

    // MARK: - 操作の層

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            titleBlock
            scrubber
                .padding(.top, 52)
            times
                .padding(.top, 14)
            pillRow
                .padding(.top, 18)
        }
        .padding(.horizontal, 96)
        .padding(.bottom, 48)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if session.isChase {
                    Text("● 録画中")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(.red, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("\(session.recording.serviceName) · \(dateRange)")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Text(session.recording.title)
                .font(DenpaFont.font(size: 44))
                .fontWeight(.bold)
                .lineLimit(2)
        }
        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
    }

    /// シークバー (3.5・milu.css の `.scrub`)。つまむ操作は tvOS に無いので、位置と CM を出すだけにする
    private var scrubber: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let fraction = session.scrubDuration > 0
                ? min(1, max(0, session.position / session.scrubDuration))
                : 0
            let recordedFraction = session.isChase && session.scrubDuration > 0
                ? min(1, max(0, session.recordedThrough / session.scrubDuration))
                : nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                if let recordedFraction {
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: width * recordedFraction)
                }
                ForEach(Array(session.chapters.enumerated()), id: \.offset) { _, chapter in
                    if chapter.title == "CM", session.scrubDuration > 0 {
                        let start = min(1, max(0, chapter.start / session.scrubDuration))
                        let end = min(1, max(0, chapter.end / session.scrubDuration))
                        Rectangle()
                            .fill(.orange)
                            .frame(width: max(0, (end - start) * width))
                            .offset(x: start * width)
                    }
                }
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction)
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 5)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                    .offset(x: width * fraction - 15)
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 34)
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                let fraction = session.scrubDuration > 0
                    ? min(1, max(0, session.position / session.scrubDuration))
                    : 0
                Text(Wording.position(Int64(session.position * 1000)))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .offset(x: max(0, proxy.size.width * fraction - 30), y: -44)
            }
        }
    }

    private var times: some View {
        HStack {
            Text(leftTime)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Spacer()
            Text(rightTime)
        }
        .font(.system(size: 24))
        .foregroundStyle(.white.opacity(0.82))
        .monospacedDigit()
    }

    private var leftTime: String {
        if session.isChase {
            return session.currentCodec.map { PlaybackRules.codecName($0) } ?? ""
        }
        return RecordingRules.chapterTitle(chapters: session.chapters, position: session.position) ?? ""
    }

    private var rightTime: String {
        if session.isChase {
            return String(localized: "\(Wording.position(Int64(session.recordedThrough * 1000))) まで録れています")
        }
        let remaining = max(0, session.duration - session.position)
        return "−" + Wording.position(Int64(remaining * 1000))
    }

    private var pillRow: some View {
        HStack(spacing: 16) {
            pill(session.isPlaying ? "一時停止" : "再生", tag: .playPause) {
                session.togglePlayCommand()
            }

            if session.isChase {
                pill("最新", tag: .latest) {
                    session.jumpToLatest()
                }
            } else if !session.chapters.isEmpty {
                pill("次のチャプター", tag: .nextChapter) {
                    if let next = RecordingRules.nextChapter(chapters: session.chapters, position: session.position) {
                        session.seek(to: next)
                    }
                }
            }

            pill(LocalizedStringKey(RecordingRules.speedName(session.speed)), tag: .speed) {
                session.setSpeed(RecordingRules.nextSpeed(after: session.speed))
            }

            if session.qualityItems.count > 1 {
                pill(qualityTitle, tag: .quality) {
                    session.selectQuality(
                        RecordingRules.nextQualityItem(items: session.qualityItems, selected: session.selectedQuality)?.codec
                    )
                }
            }

            if !session.rungItems.isEmpty {
                pill("解像度 \(rungTitle)", tag: .rung) {
                    let items = session.rungItems
                    // 押すまでに音声だけの応答で欄が消えていたら何もしない
                    guard !items.isEmpty else { return }
                    let index = items.firstIndex { $0.rung == session.selectedRung } ?? 0
                    session.selectRung(items[(index + 1) % items.count].rung)
                }
            }

            if session.hasCaptions {
                pill(captionsTitle, tag: .captions) {
                    session.setCaptionsOn(!session.captionsOn)
                }
            }

            if !session.isChase {
                pill(cmSkipTitle, tag: .cmSkip) {
                    session.setCmSkip(!session.cmSkipEnabled)
                }
            }

            if session.audioTracks.count > 1 {
                pill(audioTitle, tag: .audio) {
                    if let next = RecordingRules.nextAudioChoice(
                        tracks: session.audioTracks,
                        selected: session.selectedAudio
                    ) {
                        session.selectAudio(next)
                    }
                }
            }
        }
        .font(.system(size: 28, weight: .semibold))
        .controlSize(.large)
        .focusSection()
    }

    /// 操作の札。外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)。
    /// 字幕・CM 飛ばしの入り切りは札の字 (オン・オフ) で示す。
    /// フォーカス中の bordered も地が tint になるので、選択を地の色だけで表さない
    private func pill(
        _ title: LocalizedStringKey,
        tag: Control,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Text(title).lineLimit(1) }
            .buttonStyle(.bordered)
            .focused($control, equals: tag)
    }

    private var captionsTitle: LocalizedStringKey {
        session.captionsOn ? "字幕 オン" : "字幕 オフ"
    }

    private var cmSkipTitle: LocalizedStringKey {
        session.cmSkipEnabled ? "CM 飛ばし オン" : "CM 飛ばし オフ"
    }

    private var qualityTitle: LocalizedStringKey {
        if let selected = session.selectedQuality {
            return LocalizedStringKey(PlaybackRules.codecName(selected))
        }
        let current = session.currentCodec.map { PlaybackRules.codecName($0) } ?? ""
        return current.isEmpty ? "自動" : "自動 (\(current))"
    }

    /// 段 0 は「元のまま」、ほかは「720p」
    private var rungTitle: String {
        session.rungItems.first { $0.rung == session.selectedRung }?.title ?? ""
    }

    private var audioTitle: LocalizedStringKey {
        if let label = session.selectedAudio?.label { return LocalizedStringKey(label) }
        return "音声"
    }

    // MARK: - 操作の列の出し入れ

    /// 出したままにする (一時停止・止まった・最後まで観たとき)
    private func showControls(focusFirstPill: Bool = false) {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = true
        // 札はこの更新で初めて階層に入るので、焦点は次の更新で当てる
        if focusFirstPill {
            focusTask?.cancel()
            focusTask = Task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                control = .playPause
            }
        }
    }

    /// 10 秒送りのときは操作の列を出して、数秒後に隠す
    private func reveal() {
        showControls()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard session.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, control == nil, session.isPlaying else { return }
            controlsVisible = false
        }
    }

    private func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        focusTask?.cancel()
        focusTask = nil
        controlsVisible = false
        control = nil
        surfaceFocused = true
    }

    // MARK: - 繋ぎ直し・止まった・最後まで観た

    private var reconnect: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("再接続中…")
                .font(.system(size: 30, weight: .semibold))
        }
        .padding(36)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
    }

    private func errorOverlay(_ stop: RecordingSession.Stop) -> some View {
        VStack(spacing: 10) {
            Text(title(of: stop))
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)
            if !message(of: stop).isEmpty {
                Text(message(of: stop))
                    .font(.system(size: 28))
                    .foregroundStyle(TVTheme.muted)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                if stop.retry {
                    Button("再試行") { session.retry() }
                        .buttonStyle(.borderedProminent)
                }
                Button("閉じる", action: close)
                    .buttonStyle(.bordered)
            }
            .font(.system(size: 28, weight: .semibold))
            .controlSize(.large)
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.92))
    }

    private func title(of stop: RecordingSession.Stop) -> String {
        switch stop.reason {
        case .noPlayableFormat: String(localized: "再生できる形式がありません")
        case .noVideo: String(localized: "この録画は再生できません")
        case .serverBusy: String(localized: "サーバーが混み合っています")
        case .emptyStream: String(localized: "映像を受信できませんでした")
        case .refused: String(localized: "再生できません")
        }
    }

    private func message(of stop: RecordingSession.Stop) -> String {
        switch stop.reason {
        case .noPlayableFormat:
            String(localized: "この Apple TV に対応した映像形式がありません。")
        case .noVideo:
            String(localized: "映像のない録画は再生できません。")
        case .refused(let message):
            message
        default:
            ""
        }
    }

    /// 最後まで観た (TV-PlayerEnd)。削除は確認を通す (3.5.3)
    private var endOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            shade(height: 620, opacity: 0.85)
            VStack(alignment: .leading, spacing: 8) {
                Text("最後まで観ました")
                    .font(.system(size: 30, weight: .semibold))
                Text(session.recording.title)
                    .font(DenpaFont.font(size: 40))
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.86))
                HStack(spacing: 20) {
                    Button("一覧へ戻る", action: close)
                        .buttonStyle(.borderedProminent)
                    Button("削除", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                }
                .font(.system(size: 28, weight: .semibold))
                .controlSize(.large)
                .padding(.top, 20)
            }
            .padding(.horizontal, 96)
            .padding(.bottom, 60)
        }
        .ignoresSafeArea()
    }

    // MARK: - その他

    private var captionImage: UIImage? {
        guard let page = session.captionPage else { return nil }
        return CaptionImage.render(page: page) { session.captionHidden($0) }
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: Double(session.recording.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(session.recording.endAt) / 1000)
        return Wording.timeRange(from: start, to: end, separator: .recording)
    }

    /// 長押しで詳細を開く。続きから再生の位置は開いた瞬間の値で止める
    private func openDetail() {
        // 1 秒未満は `detailResumeMs` の中で「再生」に倒れる。ここで nil にすると保存された位置に落ちてしまう
        detailResumeMs = Int64(session.position * 1000)
        showDetail = true
    }

    /// 詳細の「再生」「続きから」は観ている所から続ける (巻き戻さない)。「最初から」だけ 0 へ戻して再生する
    private func playDetail(from: Double?) {
        if let from, from < 1 {
            session.seek(to: 0)
        }
        session.play()
    }

    private func close() {
        guard !closing else { return }
        closing = true
        Task {
            await session.close()
            onClose()
        }
    }

    private func deleteRecording() async {
        do {
            _ = try await app.delete("api/recordings/\(session.recording.id)")
            close()
        } catch AppModel.APIError.http(_, let message) {
            alertMessage = message ?? String(localized: "しばらくしてから、もう一度お試しください。")
        } catch {
            alertMessage = String(localized: "しばらくしてから、もう一度お試しください。")
        }
    }
}
