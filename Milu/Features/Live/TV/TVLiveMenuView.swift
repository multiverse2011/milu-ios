import SwiftUI

/// ライブのメニュー (TV-Live)。映像の上に、いまの局・操作の列・種別ごとの局の列を出す。
/// リモコンの 下・決定で開き、上でいまの局にフォーカスする (3.5.1)。
/// tvOS ではタブの根でもこれを出し、映像を観ていないときの局一覧にする。
struct TVLiveMenuView: View {
    let model: LiveModel
    let baseURL: URL?
    let token: String?
    /// 開いたときにフォーカスする的
    let target: TVLiveFocus
    @FocusState.Binding var focus: TVLiveFocus?
    let onSelect: (Service) -> Void
    var style: Style = .overlay

    /// 置き場所で変わる見た目。映像の上に重ねるか、タブの根の局一覧か
    enum Style {
        /// 映像の上のオーバーレイ。いまの局の見出しと操作の列を出し、上を大きく空けて幕を敷く
        case overlay
        /// タブの根の局一覧。見出しと操作の列を出さず、幕も敷かない
        case root

        var showsHeader: Bool { self == .overlay }
        var topPadding: CGFloat { self == .overlay ? 340 : 40 }
        var showsScrim: Bool { self == .overlay }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if style.showsHeader, let current = model.current {
                    TVServiceHeader(
                        service: current,
                        baseURL: baseURL,
                        token: token,
                        quality: TVLiveText.quality(model.session)
                    )
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        TVProgressBar(value: TVLiveText.progress(current.now, now: context.date))
                            .padding(.top, 56)
                    }
                    controls.padding(.top, 42)
                }
                ForEach(model.types, id: \.rawValue) { type in
                    section(type)
                }
            }
            .padding(.horizontal, 96)
            .padding(.top, style.topPadding)
            .padding(.bottom, 80)
        }
        .background {
            if style.showsScrim {
                // 明るい映像でもヘッダの字が 4.5:1 で読めるよう、メニューの間は全面を暗くする。
                // 画面案の帯 (下 780・40% で 0.82) の濃さは保ち、上も 0.55 から暗くする
                LinearGradient(
                    stops: [
                        .init(color: TVTheme.scrim.opacity(0.62), location: 0),
                        .init(color: TVTheme.scrim.opacity(0.84), location: 0.4),
                        .init(color: TVTheme.scrim.opacity(0.95), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }
        }
        .defaultFocus($focus, target, priority: .userInitiated)
    }

    // MARK: - 操作の列

    private var controls: some View {
        let session = model.session
        return HStack(spacing: 18) {
            Text("画質")
                .font(.system(size: 22))
                .foregroundStyle(TVTheme.muted)
            ForEach(Array((session?.qualityItems ?? []).enumerated()), id: \.offset) { index, item in
                chip(
                    TVLiveText.qualityItemTitle(item, session: session),
                    selected: item.codec == session?.selectedQuality,
                    focus: .quality(index)
                ) {
                    model.selectQuality(item.codec)
                }
            }
            if session?.rungItems.isEmpty == false {
                Text("解像度")
                    .font(.system(size: 22))
                    .foregroundStyle(TVTheme.muted)
            }
            ForEach(session?.rungItems ?? [], id: \.rung) { item in
                chip(
                    item.title,
                    selected: item.rung == session?.selectedRung,
                    focus: .rung(item.rung)
                ) {
                    model.selectRung(item.rung)
                }
            }
            if session?.hasCaptions == true {
                chip(
                    session?.captionsOn == true ? String(localized: "字幕 オン") : String(localized: "字幕 オフ"),
                    selected: session?.captionsOn == true,
                    focus: .captions
                ) {
                    model.setCaptionsOn(!(session?.captionsOn ?? false))
                }
            }
            // 音声は選べるものを並べる (画面案 TV-Live の「主音声」)
            ForEach(session?.audioTracks ?? [], id: \.id) { track in
                chip(
                    track.label,
                    selected: track.id == session?.selectedAudio?.id,
                    focus: .audio(track.id)
                ) {
                    model.selectAudio(track)
                }
            }
            if let now = model.current?.now {
                let recording = now.reserved || now.recording
                chip(
                    recording ? String(localized: "● 録画中") : String(localized: "● 録画"),
                    selected: recording,
                    recording: recording,
                    focus: .record
                ) {
                    model.toggleRecord()
                }
            }
        }
        .font(.system(size: 28, weight: .semibold))
        .controlSize(.large)
        .focusSection()
    }

    /// 操作の列の 1 つ。選択中・録画中は字 (✓・● 録画中) で示す。フォーカス中の
    /// bordered も地が tint になるので、地の色だけで選択を表すと見分けられない。
    /// 札の形を状態で切り替えると、押した直後にフォーカスが隣の札へ移るため、
    /// スタイルは bordered の 1 つに固定する (#75)
    private func chip(
        _ title: String,
        selected: Bool,
        recording: Bool = false,
        focus value: TVLiveFocus,
        action: @escaping () -> Void
    ) -> some View {
        let marked = selected && !recording ? "✓ \(title)" : title
        return Button(marked, action: action)
            .buttonStyle(.bordered)
            .tint(recording ? TVTheme.record : Color.accentColor)
            .focused($focus, equals: value)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 種別ごとの局の列

    private func section(_ type: ServiceType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(type.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(TVTheme.body)
                .padding(.top, 24)
                .padding(.leading, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 26) {
                    ForEach(model.services.filter { $0.type == type }, id: \.id) { service in
                        stationCard(service)
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 4)
            }
            // 先頭・末尾のカードのフォーカス枠と拡大が横の端で切れないようにする (#71。
            // 録画・検索の横の列と同じ作り)
            .scrollClipDisabled()
            .focusSection()
        }
    }

    private func stationCard(_ service: Service) -> some View {
        let isCurrent = service.id == model.current?.id
        return Button {
            onSelect(service)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    if let key = service.remoteControlKey {
                        Text("\(key)")
                            .font(.system(size: 24))
                            .foregroundStyle(TVTheme.muted)
                            .frame(width: 18, alignment: .leading)
                    }
                    TVServiceLogo(service: service, baseURL: baseURL, token: token)
                    Spacer(minLength: 8)
                    marks(service)
                    if isCurrent {
                        if model.isPlaybackOpen {
                            Text("視聴中")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(TVTheme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            // 枠の代わりの印。再生していない間は「いま選んである局」だけを示す
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Text("いま選んでいる局"))
                        }
                    }
                }
                Text(service.name)
                    .font(DenpaFont.font(size: 32))
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(service.now?.title ?? "")
                    .font(DenpaFont.font(size: 25))
                    .foregroundStyle(TVTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(width: 440, height: 180, alignment: .topLeading)
        }
        .buttonStyle(.card)
        .focused($focus, equals: .station(service.id))
    }

    @ViewBuilder
    private func marks(_ service: Service) -> some View {
        if service.now?.recording == true {
            Text("● 録画中")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(TVTheme.record)
        } else if service.now?.reserved == true {
            Text("✓ 予約済み")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}

