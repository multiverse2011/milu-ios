import SwiftUI

/// 番組の詳細 (3.5・iPhone-Program ほか・iPad もシート)。状態とボタンは ProgramActions、
/// ジャンルの名前は GenreName、時刻と長さは Wording。
struct ProgramSheetView: View {
    let item: GuideProgramItem
    let model: any ProgramSheetModel

    /// iPad かどうか。シートの中の size class は当てにならないので、開いた側から渡す
    let horizontalSizeClassRegular: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var detail: ProgramDetail?
    @State private var alertMessage: String?
    @State private var confirmingStop = false

    private var isRegular: Bool { horizontalSizeClassRegular }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isRegular {
                    HStack {
                        Spacer(minLength: 0)
                        closeButton
                    }
                }
                headerRow
                    .padding(.top, isRegular ? 0 : 18)
                Text(item.name)
                    .font(DenpaFont.font(size: isRegular ? 24 : 22))
                    .bold()
                    .lineSpacing(2)
                    .padding(.top, 8)
                factLine
                    .padding(.top, 8)
                if actions.showsProgress {
                    ProgressView(value: progress)
                        .tint(Color.accentColor)
                        .padding(.top, 10)
                }
                statusRows
                    .padding(.top, 8)
                buttons
                    .padding(.top, 16)
                extendedViews
                    .padding(.top, 20)
            }
            .padding(.horizontal, isRegular ? 28 : 20)
            .padding(.top, isRegular ? 20 : 6)
            .frame(maxWidth: 580, alignment: .leading)
        }
        .presentationDragIndicator(isRegular ? .hidden : .visible)
        .task {
            detail = await model.detail(item)
        }
        .alert("操作できません", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            "録画を停止しますか？",
            isPresented: $confirmingStop,
            titleVisibility: .visible
        ) {
            Button("録画を停止", role: .destructive) {
                Task { await cancel() }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// iPad の右上の閉じる (iPad-Program)
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .scaledFont(15, weight: .semibold)
                .frame(width: 32, height: 32)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
        .accessibilityLabel("閉じる")
    }

    // MARK: 頭の行

    private var headerRow: some View {
        HStack(spacing: 8) {
            ChannelLogoView(path: item.logo, serviceName: item.serviceName)
            Text(GuideText.sheetHeader(
                serviceName: item.serviceName,
                startAt: Date(timeIntervalSince1970: Double(item.startAt) / 1000),
                endAt: Date(timeIntervalSince1970: Double(item.endAt) / 1000),
                now: Date()
            ))
            .scaledFont(14)
            .foregroundStyle(.secondary)
        }
    }

    /// 「ジャンル › 中分類 · 長さ」(放送中なら「放送中 · あと n 分」も。画面案どおり)
    private var factLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(genreDotColor)
                .frame(width: 7, height: 7)
            Text(factText)
                .scaledFont(13.5)
                .foregroundStyle(.secondary)
        }
    }

    private var factText: String {
        var parts: [String] = []
        if let label = GenreName.label(details: genreDetails) {
            parts.append(label)
        }
        parts.append(Wording.duration(durationMs))
        for status in actions.statuses {
            if case .onAir = status {
                parts.append(status.text)
            }
        }
        return parts.joined(separator: " · ")
    }

    private var genreDetails: [(lv1: Int, lv2: Int)] {
        detail?.genreDetail?.map { (lv1: $0.lv1, lv2: $0.lv2) } ?? []
    }

    private var durationMs: Int64 { item.endAt - item.startAt }

    private var genreDotColor: Color {
        guard let rgba = GenreColor.color(item.genre) else { return Color.secondary }
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    // MARK: 状態とボタン (3.5 の表)

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

    private var progress: Double {
        guard let status = actions.statuses.first(where: { status in
            if case .onAir = status { return true }
            return false
        }), case .onAir(let elapsedMs, let totalMs) = status else {
            return 0
        }
        guard totalMs > 0 else { return 0 }
        return min(max(Double(elapsedMs) / Double(totalMs), 0), 1)
    }

    /// 放送中でない状態の行 (✓ 予約済み・⚠︎ 競合・理由)
    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(actions.statuses.enumerated()), id: \.offset) { _, status in
                if case .onAir = status {
                    EmptyView()
                } else {
                    Text(status.text)
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(color(of: status))
                }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            ForEach(Array(actions.buttons.enumerated()), id: \.offset) { _, button in
                switch button {
                case .reserve:
                    SheetButton(title: button.title, style: .primary) {
                        Task { await reserve() }
                    }
                case .watchLive:
                    SheetButton(title: button.title, style: .primary) {
                        model.watchLive(currentItem)
                        dismiss()
                    }
                case .record:
                    SheetButton(title: button.title, style: .record) {
                        Task { await reserve() }
                    }
                case .recordingNow:
                    SheetButton(title: button.title, style: .record) {
                        confirmingStop = true
                    }
                case .cancelReservation:
                    SheetButton(title: button.title, style: .destructive) {
                        Task { await cancel() }
                    }
                }
            }
        }
    }

    private var extendedViews: some View {
        ForEach(Array(GuideText.extendedItems(detail?.extended ?? [:]).enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 0) {
                Text(GuideText.extendedHeading(entry.heading))
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                Text(entry.body)
                    .font(DenpaFont.font(size: isRegular ? 15 : 14))
                    .lineSpacing(2)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: 操作

    /// 予約 (いまの番組を録るも同じ)。失敗と「200 だが録らない」は alert (3.5)
    private func reserve() async {
        if let message = await model.reserve(currentItem) {
            alertMessage = message
        }
    }

    private func cancel() async {
        if let message = await model.cancel(currentItem) {
            alertMessage = message
        }
    }

    private func color(of status: ProgramStatus) -> Color {
        switch status {
        case .onAir:
            Color.secondary
        case .reserved:
            Color.accentColor
        case .conflict:
            Color.orange
        case .reason:
            Color.secondary
        }
    }
}

/// 詳細のボタン (画面案の .bb。primary は主の色、destructive は赤の薄い地、record は赤の薄い地で 44pt)。
private struct SheetButton: View {
    enum Style {
        case primary
        case destructive
        case record
    }

    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(style == .record ? 15 : 17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .frame(height: style == .record ? 44 : 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch style {
        case .primary: Color(red: 0, green: 0.075, blue: 0.122)
        case .destructive, .record: Color.red
        }
    }

    private var background: Color {
        switch style {
        case .primary: Color.accentColor
        case .destructive, .record: Color.red.opacity(0.18)
        }
    }
}
