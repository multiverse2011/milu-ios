import SwiftUI

/// tvOS の録画・追っかけの再生 (TV-Player・TV-Chase・TV-PlayerEnd)。
/// リモコンの割り当ては design.md 3.5.1: 左右で 10 秒戻す/送る、下でシークバーと操作の列、
/// 決定で一時停止・再開、決定の長押しで番組の詳細、戻るで一覧へ。
/// 操作の列はふだん出さない。下・上で出して札へ焦点を移し、映像の面へ戻る (上・Menu) と隠す。
/// 一時停止中は自動では隠さない。止まったとき・最後まで観たときは、その画面のボタンを出す。
/// 操作の列の高さ (controlsHeight) から字幕の持ち上げ量を決めているので、題と操作の列の字は固定の大きさのままにする。
/// 題だけは放送の字なので .title2 に揃える (旧 44pt。行の高さの差は controlsHeight に足してある)。
struct TVRecordingPlayerView: View {
    let session: RecordingSession
    /// ここから録画を消した。呼び手は、消えた録画へ戻ろうとしていたなら手放す
    var onDeleted: () -> Void = {}
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

    /// 操作の列のフォーカスの的。選ぶものは項目ごとの 1 つのメニューに当てる
    private enum Control: Hashable {
        case playPause, nextChapter, latest, speed, quality, captions, audio
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
        .onAppear { surfaceFocused = true }
        .onDisappear {
            hideTask?.cancel()
            focusTask?.cancel()
            Task { await session.close() }
        }
        // 札から映像の面へ戻ったら、再生中は操作の列を隠す。メニューを閉じたときも焦点が
        // 面へ戻ることがあり、すぐ隠すと選んだ直後に列が消えてボタンが効かないように見える。
        // ここは 4 秒の自動で隠す仕組みに任せる (詳細の sheet は onDismiss で即時に隠す)
        .onChange(of: surfaceFocused) { _, focused in
            guard focused, controlsVisible, session.isPlaying, session.stop == nil, !session.finished else { return }
            scheduleHide()
        }
        // 一時停止したら操作の列を出したままにする (再生が始まったらまた隠してよい)
        .onChange(of: session.isPlaying) { _, playing in
            if playing {
                scheduleHide()
            } else if session.stop == nil, !session.finished {
                showControls()
            }
        }
        .sheet(isPresented: $showDetail, onDismiss: detailDismissed) {
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
            .background(.background)
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
                // 長押しとタップは排他。長押しのあとに来る決定で再生/一時停止を動かさない (3.5.1)
                .gesture(
                    LongPressGesture(minimumDuration: 0.6)
                        .onEnded { _ in openDetail() }
                        .exclusively(before: TapGesture().onEnded { session.togglePlayCommand() })
                )
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

    /// 字幕を持ち上げる量。操作の列 (下から約 355pt) の上へ、字幕の面の字の下端が来るようにする
    private func captionLift(height: CGFloat) -> CGFloat {
        guard height > 0, let page = session.captionPage else { return 0 }
        let span = CaptionLayout.inkSpan(page: page)
        let top = height - Self.controlsHeight
        return max(0, span.bottom * height - top + 16)
    }

    /// 操作の列の高さの見積り (題・シークバー・時刻・札・下の余白)。
    /// 340 は題が旧 44pt のときの値。DenpaFont の行の高さ (1.122 × 大きさ) の差 14.6 を足す。
    /// 題が 2 行になると差は約 29 になる (340 は 1 行の前提なので、実寸は画面で測る)
    private static let controlsHeight: CGFloat = 355

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
                        .background(TVTheme.record, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("\(session.recording.serviceName) · \(dateRange)")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Text(session.recording.title)
                .font(DenpaFont.font(.title2))
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
            // 動かす (選ばない) ものはボタンのまま
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

            // 選ぶものは項目ごとに 1 つのメニューにし、値を押すたびに回す札をやめる
            speedMenu
            qualityMenu
            captionsMenu
            audioMenu
        }
        .controlSize(.large)
        .focusSection()
    }

    /// 速度のメニュー
    private var speedMenu: some View {
        let value = RecordingRules.speedName(session.speed)
        return Menu {
            ForEach(RecordingRules.speeds, id: \.self) { speed in
                TVMenuOption(title: RecordingRules.speedName(speed), selected: speed == session.speed) {
                    session.setSpeed(speed)
                }
            }
        } label: {
            TVMenuLabel(name: "速度", value: value)
        }
        .buttonStyle(.bordered)
        .focused($control, equals: .speed)
        .accessibilityLabel(Text("速度"))
        .accessibilityValue(Text(value))
    }

    /// 画質と解像度のメニュー。どちらも映像の質の選びなので 1 つのボタンにまとめる
    @ViewBuilder
    private var qualityMenu: some View {
        let showsQuality = session.qualityItems.count > 1
        let showsRung = !session.rungItems.isEmpty
        if showsQuality || showsRung {
            let name: LocalizedStringKey = showsQuality ? "画質" : "解像度"
            let quality = TVLiveText.quality(selected: session.selectedQuality, current: session.currentCodec)
            let rungSuffix = session.selectedRung != 0 && !rungTitle.isEmpty ? "・\(rungTitle)" : ""
            let value = showsQuality ? quality + rungSuffix : rungTitle
            Menu {
                if showsQuality {
                    Section("画質") {
                        ForEach(Array(session.qualityItems.enumerated()), id: \.offset) { _, item in
                            TVMenuOption(
                                title: qualityOptionTitle(item),
                                selected: item.codec == session.selectedQuality
                            ) {
                                session.selectQuality(item.codec)
                            }
                        }
                    }
                }
                if showsRung {
                    Section("解像度") {
                        ForEach(session.rungItems, id: \.rung) { item in
                            TVMenuOption(title: item.title, selected: item.rung == session.selectedRung) {
                                session.selectRung(item.rung)
                            }
                        }
                    }
                }
            } label: {
                TVMenuLabel(name: name, value: value)
            }
            .buttonStyle(.bordered)
            .focused($control, equals: .quality)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(value))
        }
    }

    /// 画質のメニューの行。「自動」にはライブと同じく、いまの形式を添える
    private func qualityOptionTitle(_ item: PlaybackRules.QualityItem) -> String {
        item.codec == nil
            ? TVLiveText.quality(selected: nil, current: session.currentCodec)
            : item.title
    }

    /// 字幕と CM 飛ばしのメニュー。どちらも入り切りだけなので、オン・オフの選択肢を
    /// 並べて 1 つのメニューにまとめる
    @ViewBuilder
    private var captionsMenu: some View {
        let showsCaptions = session.hasCaptions
        let showsCM = !session.isChase
        if showsCaptions || showsCM {
            let captions = session.captionsOn ? String(localized: "オン") : String(localized: "オフ")
            let cm = session.cmSkipEnabled ? String(localized: "オン") : String(localized: "オフ")
            // 両方まとめたときは、どちらの状態も外から分かるようにする。
            // 値は状態だけ (「オン・オン」)。CM は題「字幕・CM」が示す
            let showsBoth = showsCaptions && showsCM
            let name: LocalizedStringKey = showsBoth ? "字幕・CM" : (showsCaptions ? "字幕" : "CM 飛ばし")
            let value = showsBoth ? "\(captions)・\(cm)" : (showsCaptions ? captions : cm)
            // 読み上げは、どちらの状態かが分かるよう項目名を添える。
            // 区切りは英語でも読めるように ASCII のカンマにする
            let spoken = showsBoth
                ? "\(String(localized: "字幕")) \(captions), \(String(localized: "CM 飛ばし")) \(cm)"
                : value
            Menu {
                if showsCaptions {
                    Section("字幕") {
                        TVMenuOption(title: String(localized: "オン"), selected: session.captionsOn) {
                            session.setCaptionsOn(true)
                        }
                        TVMenuOption(title: String(localized: "オフ"), selected: !session.captionsOn) {
                            session.setCaptionsOn(false)
                        }
                    }
                }
                if showsCM {
                    Section("CM 飛ばし") {
                        TVMenuOption(title: String(localized: "オン"), selected: session.cmSkipEnabled) {
                            session.setCmSkip(true)
                        }
                        TVMenuOption(title: String(localized: "オフ"), selected: !session.cmSkipEnabled) {
                            session.setCmSkip(false)
                        }
                    }
                }
            } label: {
                TVMenuLabel(name: name, value: value)
            }
            .buttonStyle(.bordered)
            .focused($control, equals: .captions)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(spoken))
        }
    }

    /// 音声のメニュー (選べるものが 2 つ以上あるとき)
    @ViewBuilder
    private var audioMenu: some View {
        let tracks = session.audioTracks
        if tracks.count > 1 {
            let value = tvAudioValue(session.selectedAudio?.label)
            Menu {
                ForEach(tracks, id: \.id) { track in
                    TVMenuOption(
                        title: track.label.isEmpty ? String(localized: "音声") : track.label,
                        selected: track.id == session.selectedAudio?.id
                    ) {
                        session.selectAudio(track)
                    }
                }
            } label: {
                TVMenuLabel(name: "音声", value: value)
            }
            .buttonStyle(.bordered)
            .focused($control, equals: .audio)
            .accessibilityLabel(Text("音声"))
            .accessibilityValue(Text(value ?? ""))
        }
    }

    /// 操作のボタン (選ばずに動かすもの)。外観・フォーカスは tvOS の標準の ButtonStyle に任せる
    private func pill(
        _ title: LocalizedStringKey,
        tag: Control,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Text(title).lineLimit(1) }
            .buttonStyle(.bordered)
            .focused($control, equals: tag)
    }

    /// 段 0 は「元のまま」、ほかは「720p」
    private var rungTitle: String {
        session.rungItems.first { $0.rung == session.selectedRung }?.title ?? ""
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
            // メニューを開いている間は焦点が映像の面にも札にも無い。ここで隠すと
            // 開いているメニューごと消えるので、映像の面へ戻っているときだけ隠す
            guard !Task.isCancelled, control == nil, surfaceFocused, session.isPlaying else { return }
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
                .font(.title3.weight(.semibold))
        }
        .padding(36)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 22))
    }

    private func errorOverlay(_ stop: RecordingSession.Stop) -> some View {
        VStack(spacing: 10) {
            Text(title(of: stop))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !message(of: stop).isEmpty {
                Text(message(of: stop))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                if stop.retry {
                    Button("再試行") { session.retry() }
                        .buttonStyle(.bordered)
                }
                Button("閉じる", action: close)
                    .buttonStyle(.bordered)
            }
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
                    .font(.title3.weight(.semibold))
                Text(session.recording.title)
                    .font(DenpaFont.font(.title2))
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                HStack(spacing: 20) {
                    Button("一覧へ戻る", action: close)
                        .buttonStyle(.bordered)
                    Button("削除", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                }
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

    /// 詳細 (sheet) を閉じたとき。再生中で列が出ていれば、以前と同じくすぐ隠す。
    /// メニューの閉じ際は sheet ではないので、こちらとは区別できる
    private func detailDismissed() {
        guard controlsVisible, session.isPlaying, session.stop == nil, !session.finished else { return }
        hideControls()
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
            onDeleted()
            close()
        } catch AppModel.APIError.http(_, let message) {
            alertMessage = message ?? String(localized: "しばらくしてから、もう一度お試しください。")
        } catch {
            alertMessage = String(localized: "しばらくしてから、もう一度お試しください。")
        }
    }
}
