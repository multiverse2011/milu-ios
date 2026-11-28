import SwiftUI

/// Apple TV の再生の画面 (TV-LiveHud・TV-LiveTuning・TV-LiveDetail)。
/// タブの根 (局の一覧) から外して fullScreenCover で出す。映像だけの間は
/// 左上の「‹ ライブ」(サイドバーをたたんだタブバー) をシステムが出さない (#72)。
/// リモコンは 決定・再生/一時停止で一時停止と再開 (再開はその時点のライブ)、
/// 下・上でメニュー、決定の長押しで詳細、戻るで一覧へ (3.5.1)。
struct TVLivePlayerView: View {
    let model: LiveModel
    /// 映像だけのときの Menu。再生をやめて局の一覧へ戻る
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @State private var overlay: Overlay = .none
    /// メニューを開いたときのフォーカスの的 (上は局の列、下は操作の列)
    @State private var menuTarget: TVLiveFocus = .quality(0)
    @State private var showsHud = false
    /// 長押しの決定を消費したか (番組情報が無く詳細を開けなかった局で、離した決定を一時停止に使わない)
    @State private var longPressConsumed = false
    @State private var hudTask: Task<Void, Never>?
    @FocusState private var focus: TVLiveFocus?

    private enum Overlay {
        case none
        case menu
        case detail
    }

    var body: some View {
        @Bindable var model = model
        return ZStack {
            Color.black
            player
        }
        .ignoresSafeArea()
        // 再生/一時停止ボタン。決定と同じ入口を通す。Now Playing の経路からも同じ押下が届くことがあるので、
        // 二重に動かないよう PlaybackSession で受け止める。
        // メニュー・詳細を開いている間も効かせる (純正と同じ。決定は overlay の間は効かせない)
        .onPlayPauseCommand {
            model.togglePlayPause()
        }
        // Menu: オーバーレイが開いていれば閉じ、映像だけなら再生をやめて局の一覧へ戻る (3.5.1)。
        // fullScreenCover の根で受けないと、システムに画面ごと閉じられる
        .onExitCommand {
            if overlay == .none {
                onClose()
            } else {
                closeOverlay()
            }
        }
        .onDisappear {
            // 閉じたら、開いていたメニューと帯を戻す (次に開いたとき前の重なりを残さない)
            overlay = .none
            showsHud = false
            hudTask?.cancel()
            hudTask = nil
        }
        .alert("録画できません", isPresented: Binding(
            get: { model.recordAlert != nil },
            set: { if !$0 { model.recordAlert = nil } }
        )) {
            Button("OK", role: .cancel) { model.recordAlert = nil }
        } message: {
            Text(model.recordAlert ?? "")
        }
        .confirmationDialog("録画を停止しますか？", isPresented: $model.showStopRecording, titleVisibility: .visible) {
            Button("録画を停止", role: .destructive) { model.stopRecording() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - 再生の画面 (映像・操作・局の列)

    private var player: some View {
        ZStack {
            video
            if isTuning {
                tuning
            }
            if isPaused, overlay == .none {
                paused
            }
            if showsBand {
                TVLiveBand(
                    service: model.current,
                    baseURL: app.server?.url,
                    token: app.server?.token
                )
            }
            if let session = model.session {
                if let stop = session.stop {
                    PlayerErrorOverlay(stop: stop, scale: 2) { session.retry() }
                } else if session.showReconnect {
                    ReconnectOverlay(scale: 2)
                }
            }
            if overlay == .menu {
                TVLiveMenuView(
                    model: model,
                    baseURL: app.server?.url,
                    token: app.server?.token,
                    target: menuTarget,
                    focus: $focus,
                    onSelect: select
                )
                // 映像から焦点を移す (fullScreenCover の中では defaultFocus だけでは移らない)
                .onAppear { focus = menuTarget }
            }
            if overlay == .detail, let service = model.current {
                TVLiveDetailView(
                    service: service,
                    baseURL: app.server?.url,
                    token: app.server?.token,
                    session: model.session,
                    detail: model.currentDetail,
                    recording: service.now?.reserved == true || service.now?.recording == true,
                    focus: $focus,
                    onToggleRecord: { model.toggleRecord() },
                    onClose: closeOverlay
                )
                .onAppear { focus = .detailRecord }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsBand)
        .animation(.easeInOut(duration: 0.2), value: overlay == .none)
        .ignoresSafeArea()
    }

    private var video: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let session = model.session {
                    VideoSurface(
                        layer: session.displayLayer,
                        overlay: captionImage(session),
                        overlayOffset: -captionLift(session: session, height: proxy.size.height)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .focusable(overlay == .none)
        .focused($focus, equals: .video)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            // メニューを開いている間の移動は中身のフォーカスに任せる
            guard overlay == .none else { return }
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            case .up: openMenu(focus: .station(model.current?.id ?? 0))
            case .down: openMenu(focus: .quality(0))
            default: break
            }
        }
        // 決定で一時停止・再開 (再開はその時点のライブ)。メニューは下・上で開く (3.5.1)
        .onTapGesture {
            // 長押しで詳細を開けなかった局では、離したときの決定を消費する
            guard !longPressConsumed else {
                longPressConsumed = false
                return
            }
            guard overlay == .none else { return }
            model.togglePlayPause()
        }
        // 決定の長押しで番組の詳細 (3.5.1)。詳細を開けたときの離した決定は overlay で受け止める
        .onLongPressGesture(minimumDuration: 0.6) {
            guard overlay == .none else { return }
            longPressConsumed = !openDetail()
        } onPressingChanged: { pressing in
            // 離したタップが来ないまま次の押下に移っても、控えを残して 1 回空振りさせない
            if pressing { longPressConsumed = false }
        }
        .defaultFocus($focus, .video)
    }

    /// 選局しています (TV-LiveTuning)。最初のコマが来るまで出す。
    private var isTuning: Bool {
        guard let session = model.session else { return false }
        return session.stop == nil && !session.showReconnect && session.phase == .loading
    }

    /// 一時停止中。接続を閉じているので絵が残らない。止まっていることが分かる面を出す
    private var isPaused: Bool {
        model.session?.stop == nil && model.session?.phase == .paused
    }

    private var paused: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.fill")
                .font(.system(size: 64, weight: .semibold))
            Text("一時停止中")
                .font(.system(size: 34, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 64)
        .padding(.vertical, 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .allowsHitTesting(false)
    }

    private var showsBand: Bool {
        overlay == .none && (showsHud || isTuning)
    }

    private var tuning: some View {
        ZStack {
            Color.black.opacity(0.5)
            HStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("選局しています")
                    .font(.system(size: 34, weight: .semibold))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - リモコン

    private func step(_ delta: Int) {
        guard let next = TVLiveText.neighbor(of: model.current, in: model.services, by: delta) else { return }
        model.select(next)
        showHud()
    }

    private func openMenu(focus target: TVLiveFocus) {
        menuTarget = target
        overlay = .menu
    }

    @discardableResult
    private func openDetail() -> Bool {
        guard model.current?.now != nil else { return false }
        overlay = .detail
        return true
    }

    private func closeOverlay() {
        overlay = .none
        Task { focus = .video }
    }

    private func select(_ service: Service) {
        model.select(service)
        closeOverlay()
        showHud()
    }

    /// 左右で局を替えた直後の下の帯 (TV-LiveHud)。しばらくしたら消す
    private func showHud() {
        showsHud = true
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            showsHud = false
        }
    }

    // MARK: - 字幕

    private func captionImage(_ session: PlaybackSession) -> UIImage? {
        // 点滅・duration の更新でも描き直せるように、映像の時刻を読む
        _ = session.rendererState.timeline
        guard let page = session.captionPage else { return nil }
        return CaptionImage.render(page: page, hidden: { session.captionHidden($0) })
    }

    /// 字幕を下の帯の上へ置く (3.5.2)。帯の高さは TVLiveBand の実寸
    private func captionLift(session: PlaybackSession, height: CGFloat) -> CGFloat {
        guard showsBand, height > 0, let page = session.captionPage else { return 0 }
        let span = CaptionLayout.inkSpan(page: page)
        guard span.bottom > span.top else { return 0 }
        let lift = span.bottom * height - (height - TVLiveBand.height)
        return min(max(0, lift), span.top * height)
    }
}
