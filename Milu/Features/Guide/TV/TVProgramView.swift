import SwiftUI

/// tvOS の番組の詳細 (TV-Program・TV-ProgramConflict)。番組表で決定すると開く。
/// 状態とボタンの決まりは iPhone/iPad と同じ (`ProgramActions`。3.5 の表)。
struct TVProgramView: View {
    let item: GuideProgramItem
    let model: any ProgramSheetModel
    let onClose: () -> Void

    /// 本文の下の余白。案内の判定からも同じ値を使う (余白だけが画面外のときは案内を出さない)
    private static let bottomPadding: CGFloat = 40

    @State private var detail: ProgramDetail?
    @State private var alertMessage: String?
    @State private var confirmingStop = false
    /// 開いたときに当てるボタン (画面案では「予約」が光る)。見た目は標準の ButtonStyle に任せる
    @FocusState private var focusedButton: Int?
    /// 押したボタンの位置。予約→予約取消のように組が変わったら同じ位置へフォーカスを戻す。
    /// nil に戻す更新でフォーカスが動かないよう、@State ではなく観測されない入れ物に置く
    private final class PressedIndex {
        var value: Int?
    }

    @State private var pressed = PressedIndex()
    /// 「録画を停止」の確かめを開いたボタンの位置 (開いていなければ nil)。
    /// 押した位置として覚えるのは、確かめで「録画を停止」を選んだ時点 (開いただけでは覚えない)
    @State private var stopIndex: Int?
    /// 200ms 後のフォーカスの当て直し。次の当て直しと、画面を閉じるときにキャンセルする
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Text(item.name)
                    .font(DenpaFont.font(.title))
                    .bold()
                    .lineSpacing(4)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
                pills
                    .padding(.top, 20)
                if actions.showsProgress {
                    progressBar
                        .padding(.top, 18)
                }
                buttons
                    .padding(.top, 36)
                if let status = statusLine {
                    Text(status.text)
                        .font(.callout)
                        .foregroundStyle(status.color)
                        .padding(.top, 22)
                }
                if let description = detail?.description ?? item.description, !description.isEmpty {
                    TVReadingText(
                        text: description, font: DenpaFont.font(.body),
                        lineSpacing: 12, scalesWithTextSize: true
                    )
                        .foregroundStyle(.primary)
                        .padding(.top, 36)
                        .frame(maxWidth: 1340, alignment: .leading)
                }
                sections
                    .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 50)
            .padding(.bottom, Self.bottomPadding)
        }
        .tvContinueHint(bottomPadding: Self.bottomPadding)
        .background(.background)
        .task {
            detail = await model.detail(item)
        }
        .onExitCommand(perform: onClose)
        .alert("操作できません", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog("録画を停止しますか？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("録画を停止", role: .destructive) {
                // 確かめを Menu で閉じただけではキャンセルの action が呼ばれる保証がないので、
                // 押した位置を覚えるのは「録画を停止」を選んだここだけにする (#87)
                pressed.value = stopIndex
                Task { await cancel() }
            }
            Button("キャンセル", role: .cancel) {
                pressed.value = nil
            }
        }
    }

    // MARK: 頭

    /// 局ロゴと「局 · 今日 16:00–17:00 · 1時間」
    private var headerRow: some View {
        HStack(spacing: 16) {
            ChannelLogoView(path: item.logo, serviceName: item.serviceName, width: 70, height: 40)
            Text(headerText)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private var headerText: String {
        let start = Date(timeIntervalSince1970: Double(item.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(item.endAt) / 1000)
        let head = GuideText.sheetHeader(serviceName: item.serviceName, startAt: start, endAt: end, now: Date())
        return "\(head) · \(Wording.duration(item.endAt - item.startAt))"
    }

    /// 状態の印とジャンル (TV-Program・TV-ProgramConflict)
    private var pills: some View {
        HStack(spacing: 12) {
            ForEach(Array(actions.statuses.enumerated()), id: \.offset) { _, status in
                switch status {
                case .conflict:
                    TVPill(background: Color.red.opacity(0.2), foreground: Color(red: 1, green: 0.48, blue: 0.42), bold: true) {
                        Text("⚠︎ 競合")
                    }
                case .reserved:
                    TVPill(background: Color.accentColor.opacity(0.2), foreground: Color.accentColor, bold: true) {
                        Text("✓ 予約済み")
                    }
                case .onAir:
                    TVPill {
                        Text(status.text)
                    }
                case .reason:
                    EmptyView()
                }
            }
            if let genre = GenreName.label(details: genreDetails) {
                TVPill {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(genreColor)
                            .frame(width: 11, height: 11)
                        Text(genre)
                    }
                }
            }
        }
    }

    /// 放送中の進みのバー (3.5 の表)
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.primary)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(width: 520, height: 8)
    }

    /// 外観・拡大・フォーカス時の字の色は tvOS の標準の ButtonStyle に任せる (#75)。
    /// 主要な操作 (ライブで観る・予約) = prominent、録画 = 録画の赤の tint、
    /// 予約の取り消し・録画の停止 = role、閉じる = bordered
    private var buttons: some View {
        HStack(spacing: 20) {
            ForEach(Array(actions.buttons.enumerated()), id: \.offset) { index, button in
                programButton(button, index: index)
                    .focused($focusedButton, equals: index)
            }
            Button("閉じる", action: onClose)
                .buttonStyle(.bordered)
                .focused($focusedButton, equals: actions.buttons.count)
        }
        .controlSize(.large)
        .defaultFocus($focusedButton, 0)
        // 予約→予約取消、録画する→録画中で枝が入れ替わるとフォーカスが外れるので、
        // 押した位置へ当て直す (TVRecordingPlayerView の札の出し入れと同じ)。
        // 当て直しは 1 回の押下につき 1 回だけにして、押していないときの読み直しで
        // フォーカスを引き戻さないようにする
        .onChange(of: actions.buttons) { _, _ in
            guard let index = pressed.value else { return }
            pressed.value = nil
            focusedButton = nil
            restoreTask?.cancel()
            restoreTask = Task {
                // 組み替えの直後はシステムのフォーカス当てが後から来て上書きされるため、
                // 1 フレームではなく、それが終わる少し待ってから押した位置へ当てる
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let count = actions.buttons.count
                guard count > 0 else { return }
                // 組が短くなっても範囲外を指さない (最後の札へ寄せる)
                focusedButton = min(index, count - 1)
            }
        }
        .onDisappear {
            restoreTask?.cancel()
            restoreTask = nil
        }
    }

    @ViewBuilder
    private func programButton(_ button: ProgramButton, index: Int) -> some View {
        switch button {
        case .reserve, .watchLive:
            Button(label(for: button)) { perform(button, index: index) }
                .buttonStyle(.borderedProminent)
        case .record:
            Button(label(for: button)) { perform(button, index: index) }
                .buttonStyle(.bordered)
                .tint(TVTheme.record)
        case .cancelReservation, .recordingNow:
            Button(label(for: button), role: .destructive) { perform(button, index: index) }
                .buttonStyle(.bordered)
        }
    }

    /// extended の項目 (「番組内容」は上の説明で出すので除く)
    private var sections: some View {
        ForEach(Array(otherSections.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 6) {
                Text(GuideText.extendedHeading(entry.heading))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                TVReadingText(
                    text: entry.body, font: DenpaFont.font(.body),
                    lineSpacing: 12, scalesWithTextSize: true
                )
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: 1340, alignment: .leading)
            .padding(.top, 20)
        }
    }

    private var otherSections: [(heading: String, body: String)] {
        GuideText.extendedItems(detail?.extended ?? [:]).filter { $0.heading != "番組内容" }
    }

    // MARK: 状態とボタン (3.5 の表)

    /// 予約・録画を読み直したあとの最新 (シートの中身を新しい状態にする)
    private var currentItem: GuideProgramItem {
        model.program(id: item.id) ?? item
    }

    private var actions: ProgramActionSet {
        programActions(
            now: Date(),
            startAt: Date(timeIntervalSince1970: Double(currentItem.startAt) / 1000),
            endAt: Date(timeIntervalSince1970: Double(currentItem.endAt) / 1000),
            reservation: currentItem.reservation.flatMap { info in
                info.state.map { ($0, info.reason) }
            },
            canWatchLive: currentItem.serviceID != nil
        )
    }

    private var statusLine: (text: String, color: Color)? {
        for status in actions.statuses {
            switch status {
            case .conflict(let reason):
                return reason.isEmpty ? nil : (reason, .orange)
            case .reason(let text):
                return text.isEmpty ? nil : (text, Color.secondary)
            case .onAir, .reserved:
                continue
            }
        }
        return nil
    }

    private var progress: Double {
        for status in actions.statuses {
            if case .onAir(let elapsedMs, let totalMs) = status {
                guard totalMs > 0 else { return 0 }
                return min(max(Double(elapsedMs) / Double(totalMs), 0), 1)
            }
        }
        return 0
    }

    private var genreDetails: [(lv1: Int, lv2: Int)] {
        detail?.genreDetail?.map { (lv1: $0.lv1, lv2: $0.lv2) } ?? []
    }

    private var genreColor: Color {
        guard let rgba = GenreColor.color(item.genre) else { return .secondary }
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    /// ボタンの字。TV-Program の画面案は「予約」「予約取消」と短く書いている
    private func label(for button: ProgramButton) -> String {
        switch button {
        case .reserve: String(localized: "予約")
        case .cancelReservation: String(localized: "予約取消")
        case .watchLive, .record, .recordingNow: button.title
        }
    }

    private func perform(_ button: ProgramButton, index: Int) {
        switch button {
        case .reserve, .record:
            pressed.value = index
            Task { await reserve() }
        case .recordingNow:
            // 確かめを閉じただけで組が変わっても、押していないボタンへフォーカスを動かさないよう、
            // 押した位置として覚えるのは「録画を停止」を選んだ時点にする (#87)
            stopIndex = index
            confirmingStop = true
        case .cancelReservation:
            pressed.value = index
            Task { await cancel() }
        case .watchLive:
            // 画面を閉じるので当て直さない
            model.watchLive(currentItem)
            onClose()
        }
    }

    /// 予約 (いまの番組を録るも同じ)。失敗と「200 だが録らない」は alert (3.5)
    private func reserve() async {
        let before = actions.buttons
        if let message = await model.reserve(currentItem) {
            alertMessage = message
            pressed.value = nil
        } else if actions.buttons == before {
            pressed.value = nil
        }
    }

    private func cancel() async {
        let before = actions.buttons
        if let message = await model.cancel(currentItem) {
            alertMessage = message
            pressed.value = nil
        } else if actions.buttons == before {
            pressed.value = nil
        }
    }
}

/// 詳細の札 (状態・ジャンル)。画面案の丸い角 8 の面
private struct TVPill<Content: View>: View {
    var background: Color?
    var foreground: Color = .primary
    var bold = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout.weight(bold ? .bold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(background.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 8))
    }
}
