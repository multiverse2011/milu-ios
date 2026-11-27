import SwiftUI
import UIKit
import os

/// 録画を観る (3.5・iPhone-Watch / iPhone-Player)。縦は映像の下に番組の中身、横は映像だけ。
struct RecordingWatchView: View {
    let session: RecordingSession
    /// 閉じた。削除して閉じたなら、削除した録画の id
    let onClose: (Int64?) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var started = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var menuHoldUntil = Date.distantPast
    @State private var preview: Double?
    @State private var showDetail = false
    @State private var confirmDelete = false
    @State private var alertMessage: String?
    @State private var detail: RecordingDetail?
    @State private var logoService: Service?
    @State private var closing = false
    @State private var videoWidth: CGFloat = 0
    /// iPad の「全画面」。向きは回さず、映像だけにする (iPad-Watch)
    @State private var videoOnly = false
    /// 直前に見た向き。同じ値の再通知で全画面の出入りを打ち消さない
    @State private var lastLandscape: Bool?

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    private var compact: Bool { verticalSizeClass == .compact }
    private var wideLayout: Bool { compact || (DeviceName.isPad && videoOnly) }
    private var showsShade: Bool { controlsVisible && !session.finished && session.stop == nil }

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        // iPad は横長で開いたとき・横へ回したときは映像だけから始める (iPad-Watch)。
        // 縦へ回したら映像だけをやめる。同じ向きのままの出入りでは発火しない
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape in
            guard DeviceName.isPad else { return }
            guard lastLandscape != isLandscape else { return }
            lastLandscape = isLandscape
            // 狭い Split View では iPad でも iPhone の縦の並びのままにする
            videoOnly = isLandscape && horizontalSizeClass == .regular
        }
        // Split View で狭くなったら映像だけをやめ、縦の並びに戻す
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass == .compact { videoOnly = false }
        }
        .statusBarHidden(wideLayout)
        .onAppear {
            // 録画は縦横どちらも許す (3.5.3)。自動横画面がオンなら最初から横を求める
            OrientationLock.shared.openRecording()
            showControls()
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
            Task { await session.close() }
            OrientationLock.shared.lock(.portrait)
        }
        .task {
            guard !started else { return }
            started = true
            await session.start()
            await loadExtras()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                session.enterBackground()
            case .active:
                session.enterForeground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        // 最初のコマが 3 秒より遅いと、出したときの時計だけでは隠れない。再生が始まったら張り直す
        .onChange(of: session.isPlaying) { _, playing in
            if playing, controlsVisible {
                scheduleHide()
            }
        }
        .sheet(isPresented: $showDetail) {
            RecordingDetailView(
                recording: session.recording,
                baseURL: app.server?.url,
                token: app.server?.token,
                logo: logoService,
                onPlay: { from in
                    showDetail = false
                    session.seek(to: from ?? RecordingRules.startPosition(resumeMs: session.recording.resumeMs))
                },
                onDelete: { _ in
                    // 詳細の確認で「削除」を押した。ここでもう一度聞かない
                    showDetail = false
                    Task { await deleteRecording() }
                }
            )
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

    // MARK: - 並び

    /// 縦・二段組・映像だけを、同じ `video` の実体のまま切り替える
    private func content(size: CGSize) -> some View {
        let isPad = DeviceName.isPad
        let landscape = size.width > size.height
        let twoColumn = isPad
            && horizontalSizeClass == .regular
            && landscape
            && !videoOnly
        let full = wideLayout
        // 画面案 iPad-Watch: 左右の余白 20・間 20・左 70%・右 25%
        let leftWidth = twoColumn ? max(320, size.width * 0.70) : size.width
        let videoHeight: CGFloat? = full ? nil : leftWidth * 9 / 16
        // 二段組と iPad の映像だけの字幕の移動量は、字幕の面を読む video の中で決める。
        // ここ (content) で読むと、字幕が届いたときに作り直されず値が古いままになる
        let liftHeight: CGFloat? = full ? min(size.width * 9 / 16, size.height) : videoHeight
        let layout = twoColumn
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 0))

        return ZStack {
            Color.black.ignoresSafeArea()
            layout {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        video(liftHeight: liftHeight, twoColumn: twoColumn)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    }
                    .frame(maxWidth: full ? .infinity : nil)
                    .frame(height: videoHeight)
                    .frame(maxHeight: full ? .infinity : nil)
                    if twoColumn {
                        headerInfo(titleSize: 22)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 14)
                    }
                }
                .frame(width: twoColumn ? leftWidth : nil)

                if twoColumn {
                    ScrollView {
                        detailsInfo
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if !full {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            headerInfo(titleSize: 20)
                            detailsInfo
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            // 二段組は画面案どおり左右に 20 の余白を置く
            .padding(.horizontal, twoColumn ? 20 : 0)
            // 上は safe area に任せる (自分で状態の帯を足すと二重に下がる)。映像だけのときは上端まで使う
            .ignoresSafeArea(edges: full ? .all : [])
        }
    }

    /// 字幕を中央のボタンに重ねないための移動量。並びと字の大きさによらず、
    /// 字幕の位置は番組ごとに違うので、面の中の字の範囲から決める (3.5.2)
    private func captionLift(height: CGFloat, wide: Bool) -> CGFloat {
        guard height > 0, let page = session.captionPage else { return 0 }
        let span = CaptionLayout.inkSpan(page: page)
        guard span.bottom > span.top else { return 0 }
        // 中央のボタン (広い並びは大きい) の下端と、下の操作の帯 (広い並びは題の行から) の間
        let buttons = height / 2 + (wide ? 52 : 44)
        let block = height - (wide ? 170 : 64)
        let lowest = span.bottom * height - block
        let highest = span.top * height - buttons
        if highest >= lowest {
            return min(max(0, lowest), highest)
        }
        // 間に入らない字幕は、中央のボタンの上へ。上端からはみ出さない
        let above = span.bottom * height - (height / 2 - (wide ? 52 : 44) - 12)
        return min(above, max(0, span.top * height - 8))
    }

    // MARK: - 映像と操作

    private func video(liftHeight: CGFloat?, twoColumn: Bool) -> some View {
        // どの並び・どの字の大きさでも、字幕を中央のボタンに重ならない所へ置く
        let lift = captionLift(height: liftHeight ?? 0, wide: wideLayout)
        return ZStack {
            Color.black
            // 字幕の有無で別の view にしない (レイヤの入れ物が作り直されて映像がちらつく)
            VideoSurface(
                layer: session.displayLayer,
                overlay: session.finished ? nil : captionImage,
                // 操作の層を出している間は、中央のボタンに重ならない所まで持ち上げる (3.5.2)
                overlayOffset: controlsVisible ? -lift : 0,
                shade: showsShade
            )
            // 操作の層より下に敷く。ボタンのタップを奪わないよう、ここでだけ受ける
            Color.clear
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { videoWidth = $0 }
                .gesture(
                    SpatialTapGesture(count: 2)
                        .exclusively(before: SpatialTapGesture(count: 1))
                        .onEnded { value in
                            guard session.stop == nil, !session.finished else { return }
                            switch value {
                            case .first(let tap):
                                // 端の 2 回は 10 秒戻す・送る。層は出したまま (3.5.3)
                                if videoWidth > 0, tap.location.x < videoWidth * 0.25 {
                                    session.skip(by: -10)
                                    showControls()
                                } else if videoWidth > 0, tap.location.x > videoWidth * 0.75 {
                                    session.skip(by: 10)
                                    showControls()
                                } else {
                                    // 中央の 2 回は層を出すだけ (消さない)
                                    showControls()
                                }
                            case .second:
                                toggleControls()
                            }
                        }
                )
            if session.showReconnect {
                ReconnectOverlay()
            }
            if let stop = session.stop {
                RecordingErrorOverlay(stop: stop) {
                    session.retry()
                    showControls()
                } onClose: {
                    closeAndFinish()
                }
            }
            if session.finished {
                RecordingEndOverlay(recording: session.recording) {
                    closeAndFinish()
                } onDelete: {
                    confirmDelete = true
                }
            }
            if controlsVisible, session.stop == nil, !session.finished {
                controls(twoColumn: twoColumn)
                    .transition(.opacity)
            }

        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    }

    private func controls(twoColumn: Bool) -> some View {
        let isPad = DeviceName.isPad
        let full = wideLayout || twoColumn
        return VStack {
            HStack(spacing: 8) {
                // どの並びでも左上が「閉じる」で、絵は × (2026-11-17 ユーザー判断)。
                // 全画面の出入りは右上で絵と名前だけ替える
                GlassCircleButton(
                    systemName: "xmark",
                    size: isPad || wideLayout ? 44 : 36
                ) {
                    closeAndFinish()
                }
                .accessibilityLabel("閉じる")
                Spacer()
                if session.canPictureInPicture {
                    PictureInPictureButton(
                        active: session.pictureInPictureActive,
                        size: isPad || wideLayout ? 44 : 36
                    ) {
                        session.togglePictureInPicture()
                    }
                }
                if isPad {
                    GlassCircleButton(
                        systemName: videoOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        size: 44
                    ) {
                        // iPad は向きを回さず、映像だけにする (iPad-Watch)
                        videoOnly.toggle()
                        noteInteraction()
                    }
                    .accessibilityLabel(videoOnly ? String(localized: "全画面表示を終了") : String(localized: "全画面表示"))
                } else if !wideLayout {
                    GlassCircleButton(systemName: "arrow.up.left.and.arrow.down.right", size: 44) {
                        OrientationLock.shared.request(.landscape)
                        noteInteraction()
                    }
                    .accessibilityLabel("全画面表示")
                } else {
                    // iPhone の横 (全画面)。右上の同じ場所で絵だけ替え、押すと縦を求める (3.5.3)
                    GlassCircleButton(systemName: "arrow.down.right.and.arrow.up.left", size: 44) {
                        OrientationLock.shared.request(.portrait)
                        noteInteraction()
                    }
                    .accessibilityLabel("全画面表示を終了")
                }
            }
            .padding(.horizontal, full ? 20 : 10)
            .padding(.top, isPad ? 10 : (wideLayout ? 16 : 10))

            Spacer()

            HStack(spacing: wideLayout ? 44 : 30) {
                GlassCircleButton(systemName: "gobackward.10", size: wideLayout ? 56 : 44) {
                    session.skip(by: -10)
                    showControls()
                }
                .accessibilityLabel("10秒戻す")
                GlassCircleButton(systemName: session.isPlaying ? "pause.fill" : "play.fill", size: wideLayout ? 76 : 60) {
                    session.togglePlay()
                    showControls()
                }
                .accessibilityLabel(session.isPlaying ? String(localized: "一時停止") : String(localized: "再生"))
                GlassCircleButton(systemName: "goforward.10", size: wideLayout ? 56 : 44) {
                    session.skip(by: 10)
                    showControls()
                }
                .accessibilityLabel("10秒進める")
            }

            Spacer()

            bottomControls
                .padding(.horizontal, wideLayout ? 62 : 14)
                .padding(.bottom, wideLayout ? 16 : 10)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: wideLayout ? 9 : 7) {
            HStack(alignment: .bottom, spacing: 12) {
                if wideLayout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.recording.title)
                            .font(DenpaFont.font(size: 17))
                            .fontWeight(.bold)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if session.isChase, !session.finished { RecordingBadge() }
                            Text(meta)
                                .scaledFont(13)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                        }
                    }
                    Spacer()
                } else {
                    Spacer()
                }
                HStack(spacing: 10) {
                    if session.isChase {
                        Button {
                            session.jumpToLatest()
                            showControls()
                        } label: {
                            Text("最新")
                                .scaledFont(15, weight: .semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: wideLayout ? 44 : 36)
                                .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("最新へ移動")
                    }
                    if session.hasCaptions || session.audioTracks.count > 1 {
                        RecordingCaptionsMenu(session: session, size: wideLayout ? 44 : 36) {
                            noteInteraction()
                        }
                    }
                    RecordingMoreMenu(session: session, isChase: session.isChase, size: wideLayout ? 44 : 36) {
                        noteInteraction()
                    } onDetail: {
                        noteInteraction()
                        showDetail = true
                    } onDelete: {
                        confirmDelete = true
                    }
                }
            }
            RecordingScrubber(
                position: session.position,
                duration: session.scrubDuration,
                recorded: session.isChase ? session.recordedThrough : nil,
                limit: session.seekLimit,
                chapters: session.isChase ? [] : session.chapters,
                preview: $preview
            ) { target in
                session.seek(to: target)
                showControls()
            }
            HStack {
                Text(Wording.position(Int64((preview ?? session.position) * 1000)))
                Spacer()
                if session.isChase {
                    Text("録画中 · \(Wording.position(Int64(session.recordedThrough * 1000)))まで録画されています")
                } else {
                    Text("−" + Wording.position(Int64(max(0, session.duration - (preview ?? session.position)) * 1000)))
                }
            }
            .scaledFont(12.5)
            .foregroundStyle(.white.opacity(0.9))
            .monospacedDigit()
            .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        }
    }

    // MARK: - 縦の番組の中身

    /// 番組名と事実の行 (縦は上、二段組は映像の下)
    private func headerInfo(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.recording.title)
                .font(DenpaFont.font(size: titleSize))
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let logoService {
                    ServiceLogo(service: logoService, baseURL: app.server?.url, token: app.server?.token)
                }
                if session.isChase, !session.finished { RecordingBadge() }
                Text("\(session.recording.serviceName) · \(dateRange)")
                    .scaledFont(13.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            Text(factLine)
                .scaledFont(13.5)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 番組の中身 (二段組は右の列)
    @ViewBuilder
    private var detailsInfo: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 0) {
                if !detail.description.isEmpty {
                    Text(detail.description)
                        .scaledFont(15)
                        .padding(.top, 14)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 決まり

    private var captionImage: UIImage? {
        guard let page = session.captionPage else { return nil }
        return CaptionImage.render(page: page) { session.captionHidden($0) }
    }

    private var meta: String {
        if session.isChase {
            let start = Date(timeIntervalSince1970: Double(session.recording.startAt) / 1000)
            let end = Date(timeIntervalSince1970: Double(session.recording.endAt) / 1000)
            return "\(session.recording.serviceName) · \(Wording.timeRange(from: start, to: end, separator: .recording))"
        }
        return "\(session.recording.serviceName) · \(dateRange)"
    }

    private var dateRange: String {
        let start = Date(timeIntervalSince1970: Double(session.recording.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(session.recording.endAt) / 1000)
        return "\(Wording.dateShort(start)) \(Wording.timeRange(from: start, to: end, separator: .recording))"
    }

    private var factLine: String {
        if session.isChase, !session.finished {
            let pos = Wording.position(Int64(max(0, session.recordedThrough) * 1000))
            return String(localized: "録画中 · \(pos)まで録画されています")
        }
        let length = Wording.duration(Int64(max(0, session.duration) * 1000))
        let format = session.currentCodec.map { PlaybackRules.codecName($0) } ?? "—"
        return String(localized: "\(length) · \(format) で再生中")
    }

    private func toggleControls() {
        if controlsVisible {
            controlsVisible = false
            hideTask?.cancel()
        } else {
            showControls()
        }
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    /// 操作の層を隠す時計を張り直す。出はしない (最初のコマが遅れても隠れるように、再生が始まったら呼ぶ)
    private func scheduleHide() {
        hideTask?.cancel()
        let hold = max(0, menuHoldUntil.timeIntervalSinceNow)
        hideTask = Task {
            // メニューを開いている間は隠さず、閉じたとみなせる所から 3 秒後に隠す
            try? await Task.sleep(for: .seconds(max(3, hold + 3)))
            guard !Task.isCancelled else { return }
            if session.isPlaying, preview == nil, Date() >= menuHoldUntil {
                controlsVisible = false
            }
        }
    }

    private func noteInteraction() {
        menuHoldUntil = Date().addingTimeInterval(6)
        showControls()
    }

    private func loadExtras() async {
        do {
            let data = try await app.get("api/recordings/\(session.recording.id)/detail")
            detail = try JSONDecoder().decode(RecordingDetail.self, from: data)
        } catch {
            Self.logger.info("recording detail failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            let data = try await app.get("api/services")
            let services = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data)
            logoService = services.first { $0.id == session.recording.serviceId }
        } catch {
            Self.logger.info("recording logo failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeAndFinish() {
        guard !closing else { return }
        closing = true
        Task {
            await session.close()
            onClose(nil)
        }
    }

    private func deleteRecording() async {
        do {
            _ = try await app.delete("api/recordings/\(session.recording.id)")
            onClose(session.recording.id)
        } catch AppModel.APIError.http(_, let message) {
            alertMessage = message ?? String(localized: "しばらくしてから、もう一度お試しください。")
        } catch {
            alertMessage = String(localized: "しばらくしてから、もう一度お試しください。")
        }
    }
}
