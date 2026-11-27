import SwiftUI

/// ライブの横・全画面 (3.5・iPhone-LivePlayer)。埋め込みと同じセッションを使い、開き直さない。
struct LivePlayerView: View {
    let model: LiveModel
    /// 埋め込みの全画面ボタンと同じ高さに置くための、上端の状態の帯
    let topInset: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
            LiveVideoSurface(
                model: model,
                isActive: model.showFullscreen,
                shade: model.controlsVisible && model.session?.stop == nil && model.session?.showReconnect == false
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            if let current = model.current, let session = model.session,
               model.controlsVisible || session.stop != nil || session.showReconnect {
                controls(current: current, session: session)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleControls() }
        .animation(.easeInOut(duration: 0.2), value: model.controlsVisible)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .onAppear {
            OrientationLock.shared.lock(.landscape)
            model.showControls()
        }
        .onDisappear {
            OrientationLock.shared.lock(.portrait)
        }
        // 再生中は裏に回っても音と全画面を保ち、再生していないときだけ接続と全画面を閉じる (#32)
        .onChange(of: scenePhase) { _, phase in
            model.handleLifecycle(isSelected: true, appPhase: LiveView.appPhase(phase), app: app)
        }
    }

    private func controls(current: Service, session: PlaybackSession) -> some View {
        VStack {
            if DeviceName.isPad {
                // iPad は埋め込みと同じ右上。絵と名前だけ「全画面表示を終了」に替える
                HStack(spacing: 8) {
                    Spacer()
                    if session.canPictureInPicture {
                        PictureInPictureButton(active: session.pictureInPictureActive, size: 44) {
                            session.togglePictureInPicture()
                        }
                    }
                    GlassCircleButton(systemName: "arrow.down.right.and.arrow.up.left", size: 44) { dismiss() }
                        .accessibilityLabel("全画面表示を終了")
                }
                .padding(.trailing, horizontalSizeClass == .regular ? 30 : 10)
                .padding(.top, horizontalSizeClass == .regular ? topInset + 10 : 10)
            } else {
                // iPhone も「全画面表示を終了」は右上 (ライブの全画面に閉じるは無い)
                HStack(spacing: 8) {
                    Spacer()
                    if session.canPictureInPicture {
                        PictureInPictureButton(active: session.pictureInPictureActive, size: 44) {
                            session.togglePictureInPicture()
                        }
                    }
                    GlassCircleButton(systemName: "arrow.down.right.and.arrow.up.left", size: 44) { dismiss() }
                        .accessibilityLabel("全画面表示を終了")
                }
                .padding(.trailing, 62)
                .padding(.top, 16)
            }
            Spacer()
            if model.controlsVisible, session.stop == nil, !session.showReconnect {
                bottomControls(current: current, session: session)
            }
        }
    }

    private func bottomControls(current: Service, session: PlaybackSession) -> some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.now?.title ?? current.name)
                            .font(DenpaFont.font(size: 17))
                            .fontWeight(.bold)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            LiveBadge()
                            Text(meta(current, now: context.date))
                                .scaledFont(13)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        if let now = current.now {
                            LiveRecordButton(recording: now.reserved || now.recording, height: 44) {
                                model.toggleRecord()
                            }
                        }
                        if session.hasCaptions || session.audioTracks.count > 1 {
                            LiveCaptionsMenu(model: model, session: session, size: 44)
                        }
                        LiveQualityMenu(model: model, session: session, size: 44)
                    }
                }
                .padding(.horizontal, 62)
                .padding(.bottom, 20)
            }
    }

    private func meta(_ service: Service, now: Date) -> String {
        guard let program = service.now else { return service.name }
        let range = Wording.timeRange(
            from: Date(timeIntervalSince1970: Double(program.startAt) / 1000),
            to: Date(timeIntervalSince1970: Double(program.endAt) / 1000),
            separator: .recording
        )
        let remaining = Wording.remaining(
            program.endAt - Int64(now.timeIntervalSince1970 * 1000),
            kind: .ago
        )
        return "\(service.name) · \(range) · \(remaining)"
    }
}
