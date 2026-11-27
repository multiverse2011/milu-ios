import SwiftUI
import UIKit

/// ライブのタブ (3.5・iPhone-Live / iPad-Live)。
struct LiveView: View {
    /// ライブのタブが選ばれているか。見えていないライブは開かない (3.5)
    let isSelected: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = LiveModel()
    @State private var hostToken = 0

    private struct LifecycleState: Equatable {
        var isSelected: Bool
        var phase: ScenePhase
    }

    static func appPhase(_ phase: ScenePhase) -> PlaybackRules.AppPhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.load {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .offline:
                OfflineView(host: app.server?.displayName ?? "") {
                    Task { await model.reload() }
                }
            case .empty:
                Text("視聴できる放送局がありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                GeometryReader { proxy in
                    content(size: proxy.size)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: isSelected) { _, selected in
            model.setTabSelected(selected)
        }
        // タブの出入りとアプリの前後をまとめて見る (#32・a901338)
        .onChange(of: LifecycleState(isSelected: isSelected, phase: scenePhase), initial: true) { _, state in
            model.handleLifecycle(
                isSelected: state.isSelected,
                appPhase: Self.appPhase(state.phase),
                app: app
            )
        }
        // PiP の窓が開いた・閉じたときも、裏の決まり (#32) を引き直す (#48)
        .onChange(of: model.session?.pictureInPictureActive) { _, _ in
            model.handleLifecycle(
                isSelected: isSelected,
                appPhase: Self.appPhase(scenePhase),
                app: app
            )
        }
        // 再ペアリングやログアウトで MainTabView ごと外れたときにも接続と Now Playing を確実に閉じる
        .onDisappear { model.stop() }
        .onChange(of: app.liveWatch, initial: true) { _, request in
            // 番組表の「ライブで観る」。その局を映す
            if let request {
                model.watch(serviceID: request.serviceID)
            }
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
        .fullScreenCover(isPresented: $model.showFullscreen, onDismiss: { hostToken += 1 }) {
            LivePlayerView(model: model, topInset: statusBarInset)
        }
    }

    private var statusBarInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }

    /// iPad の横長は二段組 (iPad-Live)。左に映像と番組、右に種別と局の一覧。
    /// 回転や Split View の出入りで枝が変わると映像の入れ物が作り直されるので、
    /// 録画と同じく AnyLayout で並びだけを替える
    private func content(size: CGSize) -> some View {
        let wide = DeviceName.isPad
            && horizontalSizeClass == .regular
            && size.width > size.height
        // 画面案 iPad-Live: 左右の余白 20・間 20・左 70%・右 25%
        let leftWidth = max(320, size.width * 0.70)
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            VStack(spacing: 0) {
                video(showsRecord: wide)
                if wide {
                    wideProgramInfo
                } else {
                    programInfo
                }
            }
            .frame(width: wide ? leftWidth : nil)

            VStack(spacing: 0) {
                if model.types.count > 1 {
                    typePicker(large: !wide)
                        .padding(.top, wide ? 16 : 0)
                }
                serviceList
            }
            .frame(maxWidth: wide ? .infinity : nil)
        }
        .padding(.horizontal, wide ? 20 : 0)
    }

    private func video(showsRecord: Bool = false) -> some View {
        ZStack {
            LiveVideoSurface(
                model: model,
                isActive: !model.showFullscreen,
                shade: model.controlsVisible && model.session?.stop == nil && model.session?.showReconnect == false
            )
            .id(hostToken)
            if model.controlsVisible, let session = model.session,
               session.stop == nil, !session.showReconnect {
                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        if session.canPictureInPicture {
                            PictureInPictureButton(
                                active: session.pictureInPictureActive,
                                size: DeviceName.isPad ? 44 : 36
                            ) {
                                session.togglePictureInPicture()
                            }
                        }
                        GlassCircleButton(
                            systemName: "arrow.up.left.and.arrow.down.right",
                            size: DeviceName.isPad ? 44 : 36
                        ) {
                            model.showFullscreen = true
                        }
                        .accessibilityLabel("全画面表示")
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        LiveBadge()
                        Spacer()
                        if showsRecord, let now = model.current?.now {
                            LiveRecordButton(recording: now.reserved || now.recording) {
                                model.toggleRecord()
                            }
                        }
                        if session.hasCaptions || session.audioTracks.count > 1 {
                            LiveCaptionsMenu(model: model, session: session)
                        }
                        LiveQualityMenu(model: model, session: session)
                    }
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleControls() }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
    }

    @ViewBuilder
    private var programInfo: some View {
        if let current = model.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.now?.title ?? current.name)
                            .font(DenpaFont.font(size: 17))
                            .fontWeight(.bold)
                            .lineLimit(1)
                        Text(meta(current, now: context.date))
                            .scaledFont(13.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        LiveProgressBar(value: progress(current, now: context.date))
                            .padding(.top, 4)
                    }
                    if let now = current.now {
                        LiveRecordButton(recording: now.reserved || now.recording) {
                            model.toggleRecord()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    /// 横長の iPad の映像の下 (iPad-Live)
    @ViewBuilder
    private var wideProgramInfo: some View {
        if let current = model.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text(meta(current, now: context.date))
                        .scaledFont(13.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(current.now?.title ?? current.name)
                        .font(DenpaFont.font(size: 21))
                        .fontWeight(.bold)
                        .lineLimit(2)
                    if !model.currentDescription.isEmpty {
                        Text(model.currentDescription)
                            .scaledFont(15)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }

    /// `large` は iPad の 1 列のときだけ。二段組の右の列は列の幅に収める (画面案 iPad-Live)
    private func typePicker(large: Bool) -> some View {
        Picker("種別", selection: Binding(
            get: { model.selectedType.rawValue },
            set: { model.selectedType = ServiceType(rawValue: $0) ?? .GR }
        )) {
            ForEach(model.types, id: \.rawValue) { type in
                Text(type.title).tag(type.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .modifier(TypePickerSize(isPad: DeviceName.isPad, large: large))
        .padding(.bottom, 6)
    }

    /// 種別の切り替え。iPad の 1 列は大きく、iPhone と二段組は今のまま
    private struct TypePickerSize: ViewModifier {
        let isPad: Bool
        let large: Bool

        func body(content: Content) -> some View {
            if isPad, large {
                content
                    .frame(width: 400, height: 44)
                    .scaledFont(17)
                    .controlSize(.large)
            } else {
                content
                    .padding(.horizontal, 20)
            }
        }
    }

    private var serviceList: some View {
        List {
            ForEach(model.services.filter { $0.type == model.selectedType }, id: \.id) { service in
                Button {
                    model.select(service)
                } label: {
                    row(service)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
                // 画面案は最後の局にも線を引く
                .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ service: Service) -> some View {
        HStack(spacing: 12) {
            ServiceLogo(service: service, baseURL: app.server?.url, token: app.server?.token)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let key = service.remoteControlKey {
                        Text("\(key)")
                            .scaledFont(13, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    Text(service.name)
                        .font(DenpaFont.font(size: 15.5))
                        .foregroundStyle(service.id == model.current?.id ? Color.accentColor : .primary)
                }
                Text(service.now?.title ?? "")
                    .font(DenpaFont.font(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if service.now?.recording == true {
                Text("● 録画中")
                    .scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(.red)
            }
            if service.id == model.current?.id {
                Image(systemName: "speaker.wave.2.fill")
                    .scaledFont(16)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }

    private func meta(_ service: Service, now: Date) -> String {
        guard let program = service.now else { return service.name }
        let range = Wording.timeRange(
            from: date(program.startAt),
            to: date(program.endAt),
            separator: .live
        )
        let remaining = Wording.remaining(program.endAt - Int64(now.timeIntervalSince1970 * 1000), kind: .ago)
        return "\(service.name) · \(range) · \(remaining)"
    }

    private func progress(_ service: Service, now: Date) -> Double {
        guard let program = service.now, program.endAt > program.startAt else { return 0 }
        let position = now.timeIntervalSince1970 * 1000
        return (position - Double(program.startAt)) / Double(program.endAt - program.startAt)
    }

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

}

/// 映像・字幕・繋ぎ直し・止まった表示を重ねた面。
struct LiveVideoSurface: View {
    let model: LiveModel
    var isActive = true
    var shade = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let session = model.session {
                    let overlay = captionImage(session)
                    VideoSurface(
                        layer: session.displayLayer,
                        isActive: isActive,
                        overlay: overlay,
                        overlayOffset: model.controlsVisible ? -captionLift(session: session, height: proxy.size.height) : 0,
                        shade: shade
                    )
                    if session.phase == .paused, session.stop == nil {
                        GlassCircleButton(systemName: "play.fill", size: DeviceName.isPad ? 76 : 60) {
                            _ = session.play()
                            model.showControls()
                        }
                        .accessibilityLabel("再生")
                    }
                    if session.showReconnect {
                        ReconnectOverlay()
                    }
                    if let stop = session.stop {
                        PlayerErrorOverlay(stop: stop) { session.retry() }
                    }
                }
            }
        }
    }

    /// 字幕を下の帯 (局・録画・メニュー) の上へ置く。再生中は中央のボタンが無い (一時停止中は字幕を消している)
    private func captionLift(session: PlaybackSession, height: CGFloat) -> CGFloat {
        guard height > 0, let page = session.captionPage else { return 0 }
        let span = CaptionLayout.inkSpan(page: page)
        guard span.bottom > span.top else { return 0 }
        let lift = span.bottom * height - (height - 100)
        return min(max(0, lift), span.top * height)
    }

    private func captionImage(_ session: PlaybackSession) -> UIImage? {
        // 点滅・duration の更新でも描き直せるように、映像の時刻を読む
        _ = session.rendererState.timeline
        guard let page = session.captionPage else { return nil }
        return CaptionImage.render(page: page, hidden: { session.captionHidden($0) })
    }
}

