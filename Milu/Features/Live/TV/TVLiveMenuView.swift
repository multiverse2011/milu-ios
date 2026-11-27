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
            // 選択肢が多いもの (画質・解像度・音声) は項目ごとに 1 つのメニュー、
            // オン/オフだけの字幕は押すたびに切り替わるボタンにする。録画は動かすボタン
            qualityMenu(session)
            captionsButton(session)
            audioMenu(session)
            if let now = model.current?.now {
                let recording = now.reserved || now.recording
                Button(recording ? String(localized: "● 録画中") : String(localized: "● 録画")) {
                    model.toggleRecord()
                }
                .buttonStyle(.bordered)
                .focused($focus, equals: .record)
                .accessibilityAddTraits(recording ? .isSelected : [])
            }
        }
        .controlSize(.large)
        .focusSection()
    }

    /// 画質と解像度のメニュー。どちらも映像の質の選びなので 1 つのボタンにまとめる。
    /// ボタンには項目名と今の値を出す (音声だけの観方では解像度が無いので出さない)
    @ViewBuilder
    private func qualityMenu(_ session: PlaybackSession?) -> some View {
        let qualityItems = session?.qualityItems ?? []
        let rungItems = session?.rungItems ?? []
        if !qualityItems.isEmpty || !rungItems.isEmpty {
            let showsQuality = !qualityItems.isEmpty
            let name: LocalizedStringKey = showsQuality ? "画質" : "解像度"
            let value = showsQuality
                ? qualityValue(session)
                : rungItems.first { $0.rung == session?.selectedRung }?.title ?? ""
            Menu {
                if !qualityItems.isEmpty {
                    Section("画質") {
                        ForEach(Array(qualityItems.enumerated()), id: \.offset) { _, item in
                            TVMenuOption(
                                title: TVLiveText.qualityItemTitle(item, session: session),
                                selected: item.codec == session?.selectedQuality
                            ) {
                                model.selectQuality(item.codec)
                            }
                        }
                    }
                }
                if !rungItems.isEmpty {
                    Section("解像度") {
                        ForEach(rungItems, id: \.rung) { item in
                            TVMenuOption(title: item.title, selected: item.rung == session?.selectedRung) {
                                model.selectRung(item.rung)
                            }
                        }
                    }
                }
            } label: {
                TVControlLabel(name: name, value: value)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .quality)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(value))
        }
    }

    /// 画質の値。解像度を選んでいるときは添える (「自動 (H.264)・540p」)
    private func qualityValue(_ session: PlaybackSession?) -> String {
        let quality = TVLiveText.quality(session)
        guard let session, session.selectedRung != 0,
              let rung = session.rungItems.first(where: { $0.rung == session.selectedRung })?.title
        else { return quality }
        return "\(quality)・\(rung)"
    }

    /// 字幕のボタン。オン/オフの 2 択だけなのでメニューにせず、押すたびに切り替える。
    /// 形とスタイルは状態で変えない (押した直後に焦点が隣のボタンへ移るため)
    @ViewBuilder
    private func captionsButton(_ session: PlaybackSession?) -> some View {
        if session?.hasCaptions == true {
            let on = session?.captionsOn == true
            let value = on ? String(localized: "オン") : String(localized: "オフ")
            Button {
                model.setCaptionsOn(!on)
            } label: {
                TVControlLabel(name: "字幕", value: value)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .captions)
            .accessibilityLabel(Text("字幕"))
            .accessibilityValue(Text(value))
        }
    }

    /// 音声のメニュー。選べるものを全部並べ、いまのものにチェックを付ける
    @ViewBuilder
    private func audioMenu(_ session: PlaybackSession?) -> some View {
        let tracks = session?.audioTracks ?? []
        if !tracks.isEmpty {
            let value = tvAudioValue(session?.selectedAudio?.label)
            Menu {
                ForEach(tracks, id: \.id) { track in
                    TVMenuOption(
                        title: track.label.isEmpty ? String(localized: "音声") : track.label,
                        selected: track.id == session?.selectedAudio?.id
                    ) {
                        model.selectAudio(track)
                    }
                }
            } label: {
                TVControlLabel(name: "音声", value: value)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .audio)
            .accessibilityLabel(Text("音声"))
            .accessibilityValue(Text(value ?? ""))
        }
    }

    // MARK: - 種別ごとの局の列

    private func section(_ type: ServiceType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(type.title)
                .font(.headline)
                .foregroundStyle(.primary)
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
            // 先頭・末尾のカードの、標準のフォーカスの浮き上がりと影が横の端で切れないようにする (#71。
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                    }
                    TVServiceLogo(service: service, baseURL: baseURL, token: token)
                    Spacer(minLength: 8)
                    marks(service)
                    if isCurrent {
                        if model.isPlaybackOpen {
                            Text("視聴中")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
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
                    .font(DenpaFont.font(.title3))
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(service.now?.title ?? "")
                    .font(DenpaFont.font(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(width: 440, height: 200, alignment: .topLeading)
        }
        .buttonStyle(.card)
        .focused($focus, equals: .station(service.id))
    }

    @ViewBuilder
    private func marks(_ service: Service) -> some View {
        if service.now?.recording == true {
            Text("● 録画中")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TVTheme.record)
        } else if service.now?.reserved == true {
            Text("✓ 予約済み")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}

