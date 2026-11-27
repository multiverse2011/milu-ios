import SwiftUI

/// Apple TV のライブのタブ (TV-Live)。根は局の一覧で、局を選ぶと再生の画面を
/// fullScreenCover で出す (#72)。モデルと再生は iPhone/iPad と同じ LiveModel・
/// PlaybackSession を使う (3.5.1)。
struct TVLiveTabView: View {
    /// ライブのタブが選ばれているか。見えていないライブは開かない (3.5)
    let isSelected: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LiveModel()
    /// 再生の画面を出しているか。再生を閉じている間は局の一覧 (タブの根) を出す
    @State private var showsPlayer = false
    /// cover が画面に出ているか。閉じアニメーションの間はまだ true (cover の onAppear で立て、onDismiss で下ろす)
    @State private var playerPresented = false
    /// cover を閉じたのがモデルの側 (一覧が空になった等) か。閉じている間に一覧が戻って
    /// 再生が開き直ったとき、onDismiss がその再生を巻き込んで閉じないようにする (#88)
    @State private var closedByModel = false
    @FocusState private var focus: TVLiveFocus?

    private struct LifecycleState: Equatable {
        var isSelected: Bool
        var phase: ScenePhase
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.load {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            case .offline:
                OfflineView(host: app.server?.displayName ?? "") {
                    Task { await model.reload() }
                }
            case .empty:
                Text("視聴できる放送局がありません")
                    .font(.system(size: 32))
                    .foregroundStyle(TVTheme.muted)
            case .ready:
                TVLiveMenuView(
                    model: model,
                    baseURL: app.server?.url,
                    token: app.server?.token,
                    target: focusTarget,
                    focus: $focus,
                    onSelect: { model.openPlayback($0) },
                    style: .root
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 映像の画面はタブの根から外す。こうすると左上の「‹ ライブ」が出ない (#72)
        .fullScreenCover(isPresented: $showsPlayer, onDismiss: dismissPlayer) {
            TVLivePlayerView(model: model) {
                showsPlayer = false
                model.closePlayback()
            }
            .onAppear { playerPresented = true }
        }
        // モデルが閉じたことで cover を閉じる。閉じている間に一覧が戻って開き直しても、
        // モデル側の閉じの最中はここで出し直さず onDismiss に任せる (同じ値の書き込みにしない) (#88)
        .onChange(of: model.isPlaybackOpen, initial: true) { _, open in
            if open {
                if !closedByModel {
                    showsPlayer = true
                }
            } else {
                if playerPresented {
                    closedByModel = true
                }
                showsPlayer = false
            }
        }
        // 閉じている間に届いた録画の失敗は一覧の側で出す。cover を出し始めてから閉じ切るまでは
        // 再生の画面に任せる (alert が cover の提示を塞がないよう、出す側をひとつに保つ) (#88)
        .alert("録画できません", isPresented: Binding(
            get: { !showsPlayer && !playerPresented && model.recordAlert != nil },
            set: { if !$0 { model.recordAlert = nil } }
        )) {
            Button("OK", role: .cancel) { model.recordAlert = nil }
        } message: {
            Text(model.recordAlert ?? "")
        }
        // タブの出入りとアプリの前後を iPhone と同じくまとめて見る (#32)
        .onChange(of: isSelected) { _, selected in
            model.setTabSelected(selected)
        }
        .onChange(of: LifecycleState(isSelected: isSelected, phase: scenePhase), initial: true) { _, state in
            model.handleLifecycle(
                isSelected: state.isSelected,
                appPhase: Self.appPhase(state.phase),
                app: app
            )
        }
        .onDisappear {
            showsPlayer = false
            model.stop()
        }
        // 番組表の「ライブで観る」
        .onChange(of: app.liveWatch, initial: true) { _, request in
            if let request {
                model.watch(serviceID: request.serviceID)
            }
        }
    }

    /// 一覧で最初にフォーカスする局 (観ていた局。`.ready` では必ずある)
    private var focusTarget: TVLiveFocus {
        .station(model.current?.id ?? model.services.first?.id ?? 0)
    }

    /// 再生の画面を閉じた。再生はこちらの onClose で閉じるが、
    /// システムに閉じられたときも再生を残さない。
    /// モデルが閉じた結果の閉じなら、閉じている間に一覧が戻って開き直した再生を巻き込まない (#88)
    private func dismissPlayer() {
        playerPresented = false
        if closedByModel {
            closedByModel = false
        } else {
            model.closePlayback()
        }
        // 開き直していたら cover を出し直す (空になった一覧のまま閉じ切らない)。
        // 閉じアニメーションの間に true へ戻していないので、ここは false → true の差になる
        showsPlayer = model.isPlaybackOpen
        guard !showsPlayer, let id = model.current?.id else { return }
        Task { focus = .station(id) }
    }

    private static func appPhase(_ phase: ScenePhase) -> PlaybackRules.AppPhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}
