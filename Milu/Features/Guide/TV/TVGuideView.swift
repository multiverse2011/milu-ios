import SwiftUI

/// tvOS の番組表 (TV-Guide)。上の段に 種別・日付、その下に局の行と格子。
/// マスはフォーカスで動き、決定で番組の詳細 (TV-Program) を全画面で開く。
struct TVGuideView: View {
    let model: GuideModel
    @Environment(AppModel.self) private var app
    @State private var opened: GuideProgramItem?

    var body: some View {
        Group {
            if model.didFail, model.guide == nil {
                unavailable
            } else if let guide = model.guide {
                TVGuideBoard(guide: guide, model: model) { opened = $0 }
            } else {
                Color.clear
            }
        }
        .task {
            await model.reload()
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        // 詳細は番組表の上に全画面で重ねる (TV-Program。サイドバーは出さない)。
        // 閉じても番組表の送り位置とフォーカスはそのまま残る
        .fullScreenCover(item: $opened) { item in
            TVProgramView(item: item, model: model, onClose: { opened = nil })
        }
    }

    /// 一覧を取れなかった (3.5 の「繋がらない」。iPhone/iPad と同じ部品の tvOS の寸法)
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("denpa に接続できません")
                .font(.title2.bold())
                .padding(.top, 10)
            Text("\(app.server?.displayName ?? "") から応答がありません。\nWi-Fi などの接続状況を確認してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button("再試行") {
                Task { await model.reload() }
            }
            .font(.callout.weight(.semibold))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 300)
    }
}

/// 番組表の格子と上の段。フォーカスは 1 つのカーソル (`GuideCursor`) で動かす。
/// 送りは自前 (格子の中の位置を決め打ちで動かす) なので、見えている分だけを作る。
private struct TVGuideBoard: View {
    let guide: GuideResponse
    let model: GuideModel
    let onOpen: (GuideProgramItem) -> Void

    private static let headerHeight = 64.0

    /// 時刻の列の幅。時の数字と分の札はテキストスタイルで字の大きさの設定に従うので、
    /// 列も同じ割合で広げる (局の行と格子はずらしにこの値を使うので一緒に動く)
    @ScaledMetric(relativeTo: .body) private var timeWidth: CGFloat = CGFloat(GuideLayout.tvTimeWidth)

    private enum Focus: Hashable {
        case type(ServiceType)
        case day(Date)
        case grid
    }

    @FocusState private var focus: Focus?
    /// いま選んでいるマス。読み直しで消えたら `resolvedCursor` が先頭に戻す
    @State private var cursor: GuideCursor?
    @State private var scroll = CGPoint.zero
    @State private var viewport = CGSize.zero
    @State private var didScroll = false

    private var from: Double { Double(GuideLayout.broadcastRange(for: model.selectedDay).from) }
    private var to: Double { Double(GuideLayout.broadcastRange(for: model.selectedDay).to) }

    private var totalHeight: Double {
        GuideLayout.height(rangeStart: from, rangeEnd: to, pointsPerMinute: GuideLayout.tvPointsPerMinute)
    }

    private var contentWidth: Double {
        max(0, Double(guide.services.count) * (GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap) - GuideLayout.tvColumnGap)
    }

    var body: some View {
        // いまの線を 1 分ごとに動かす (iPhone の GuideGrid と同じ)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .onChange(of: viewport) { _, _ in
            guard !didScroll, viewport.height > 0 else { return }
            didScroll = true
            reset()
        }
        .onChange(of: model.selectedDay) { _, _ in reset() }
        .onChange(of: model.selectedType) { _, _ in reset() }
        // 読み直しで局が減ると表の幅が縮む。古い送り位置のままだと全部が画面の外に出る
        .onChange(of: guide.services.count) { _, _ in
            scroll = CGPoint(x: clampX(scroll.x), y: scroll.y)
        }
    }

    private func content(now: Date) -> some View {
        VStack(spacing: 0) {
            chips(now: now)
            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: max(geo.size.height - Self.headerHeight - 8, 0))
                VStack(spacing: 8) {
                    header(width: size.width)
                    grid(size: size, now: now)
                }
                .onChange(of: size, initial: true) { _, new in
                    viewport = new
                }
            }
            .padding(.trailing, 40)
            .padding(.bottom, 10)
        }
    }

    // MARK: 上の段

    private func chips(now: Date) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 40) {
                HStack(spacing: 8) {
                    ForEach(model.availableTypes, id: \.self) { type in
                        chip(
                            GuideText.typeLabel(type),
                            active: type == model.selectedType,
                            focus: .type(type)
                        ) {
                            model.selectType(type)
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(model.menuDays, id: \.self) { day in
                        chip(
                            GuideLayout.dayChipLabel(for: day, today: now),
                            active: GuideLayout.calendar.isDate(day, inSameDayAs: model.selectedDay),
                            focus: .day(day)
                        ) {
                            model.selectDay(day)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        // 高さは標準のチップに合わせる (固定にするとフォーカスの大きさで切れる)
        .fixedSize(horizontal: false, vertical: true)
        .scrollClipDisabled()
        .padding(.trailing, 40)
        .padding(.top, 28)
    }

    /// 種別・日付のチップ (TV-Guide)。外観・拡大・フォーカス時の字の色は tvOS の標準に任せる。
    /// 選んでいるものは ✓ で示し、フォーカスと区別できるようにする
    private func chip(
        _ label: String,
        active: Bool,
        focus value: Focus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(active ? "✓ \(label)" : label)
                .font(.callout.weight(active ? .bold : .medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .focused($focus, equals: value)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: 局の行と格子

    /// 局の行。幅は格子と同じ見えている幅に切り取る (でないと広い表で VStack が横に伸び、
    /// 格子が中央へ寄る)。中身は送り位置ぶん左へずらす
    private func header(width: Double) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: GuideLayout.tvColumnGap) {
                ForEach(guide.services, id: \.id) { service in
                    HStack(spacing: 10) {
                        ChannelLogoView(path: service.logo, serviceName: service.name, width: 52, height: 30)
                        if let key = service.remoteControlKey {
                            Text("\(key)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(service.name)
                            .font(DenpaFont.font(.callout))
                            .bold()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: GuideLayout.tvColumnWidth, height: Self.headerHeight, alignment: .leading)
                }
            }
            .offset(x: timeWidth - scroll.x)
        }
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
        .clipped()
    }

    private func grid(size: CGSize, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            columns(size: size, now: now)
                .offset(x: timeWidth - scroll.x, y: -scroll.y)
            timeColumn(now: now)
                .offset(y: -scroll.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .grid)
        .onMoveCommand { move($0, now: now) }
        .onTapGesture { open(now: now) }
        // 格子は 1 つのまとまりなので、読み上げは選んでいる番組だけにする
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cursorLabel(now: now))
        // Button をやめた (tvOS 26/27 では Button に focusEffectDisabled を付けても格子を囲む縁が消えないため)、
        // 押せることと決定の動きは自前で持つ
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(now: now) }
    }

    /// マス・過ぎた所の黒・いまの線。見えている範囲と前後だけを作る
    private func columns(size: CGSize, now: Date) -> some View {
        let rows = rowRange(size: size)
        let nowY = nowOffset(now: now)
        let focused = focus == .grid ? resolvedCursor(now: now)?.programID : nil
        return ZStack(alignment: .topLeading) {
            ForEach(Array(columnRange(size: size)), id: \.self) { column in
                ForEach(cells(in: column, rows: rows), id: \.item.id) { cell in
                    TVGuideCell(
                        item: cell.item,
                        height: max(cell.height - GuideLayout.tvColumnGap, 2),
                        focused: focused == cell.item.id
                    )
                    .offset(
                        x: Double(column) * (GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap),
                        y: cell.top + GuideLayout.tvColumnGap / 2
                    )
                    // フォーカス中のマスは過ぎた所の黒より上に描く (画面案の z の順)
                    .zIndex(focused == cell.item.id ? 1 : 0)
                }
            }
            if let nowY {
                // 過ぎた所はマスの上に重ねる (画面案の z)。当たりは取らない
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: contentWidth, height: nowY)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: contentWidth, height: 2)
                    .offset(y: nowY)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
    }

    /// 時刻の列。時の数字と、いまの線の左に出す分 (TV-Guide の画面案)。
    /// 地の色で塗って切り取る (横に送ったマスがここへ潜り込まないように)
    private func timeColumn(now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                let time = from + Double(hour) * 3_600_000
                Text("\(GuideLayout.calendar.component(.hour, from: Date(timeIntervalSince1970: time / 1000)))")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .offset(y: GuideLayout.offset(of: time, from: from, pointsPerMinute: GuideLayout.tvPointsPerMinute) + 6)
            }
            if let nowY = nowOffset(now: now) {
                Text("\(GuideLayout.calendar.component(.minute, from: now))")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .offset(y: nowY - 14)
            }
        }
        .frame(width: timeWidth, height: totalHeight, alignment: .topLeading)
        .background(.background)
        .clipped()
    }

    private func nowOffset(now: Date) -> Double? {
        let today = GuideLayout.calendar.isDate(model.selectedDay, inSameDayAs: GuideLayout.broadcastDay(for: now))
        guard today else { return nil }
        return GuideLayout.nowOffset(
            now: now.timeIntervalSince1970 * 1000,
            rangeStart: from,
            rangeEnd: to,
            pointsPerMinute: GuideLayout.tvPointsPerMinute
        )
    }

    private func resolvedCursor(now: Date) -> GuideCursor? {
        if let cursor, GuideCursorMotion.program(cursor, in: guide.services) != nil {
            return cursor
        }
        return GuideCursorMotion.initial(in: guide.services, now: Int64(now.timeIntervalSince1970 * 1000))
    }

    // MARK: 作る範囲

    private func columnStep() -> Double {
        GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap
    }

    private func columnRange(size: CGSize) -> Range<Int> {
        GuideLayout.tvColumnRange(scrollX: scroll.x, width: Double(size.width), count: guide.services.count)
    }

    private func rowRange(size: CGSize) -> ClosedRange<Double> {
        let margin = 300.0
        return max(0, scroll.y - margin)...(scroll.y + Double(size.height) + margin)
    }

    private func cells(
        in column: Int,
        rows: ClosedRange<Double>
    ) -> [(item: GuideProgramItem, top: Double, height: Double)] {
        let service = guide.services[column]
        return service.programs.compactMap { program in
            guard let frame = GuideLayout.frame(
                start: Double(program.startAt),
                end: Double(program.endAt),
                rangeStart: from,
                rangeEnd: to,
                pointsPerMinute: GuideLayout.tvPointsPerMinute
            ),
                frame.top <= rows.upperBound,
                frame.top + frame.height >= rows.lowerBound
            else { return nil }
            return (GuideProgramItem(service: service, program: program), frame.top, frame.height)
        }
    }

    // MARK: フォーカスと送り

    private func move(_ direction: MoveCommandDirection, now: Date) {
        let services = guide.services
        let current = resolvedCursor(now: now)
        let moved: GuideCursor? = switch direction {
        case .left: current.flatMap { GuideCursorMotion.horizontal($0, in: services, by: -1) }
        case .right: current.flatMap { GuideCursorMotion.horizontal($0, in: services, by: 1) }
        case .up: current.flatMap { GuideCursorMotion.vertical($0, in: services, by: -1) }
        case .down: current.flatMap { GuideCursorMotion.vertical($0, in: services, by: 1) }
        default: nil
        }
        if let moved {
            cursor = moved
            follow(moved)
        } else if direction == .up {
            // 一番上の番組からは、上の段 (日付) へ抜ける
            focus = .day(model.selectedDay)
        }
    }

    private func open(now: Date) {
        guard let cursor = resolvedCursor(now: now),
              let (column, program) = GuideCursorMotion.program(cursor, in: guide.services)
        else { return }
        onOpen(GuideProgramItem(service: guide.services[column], program: program))
    }

    /// 読み上げる字 (選んでいるマス)
    private func cursorLabel(now: Date) -> String {
        guard let cursor = resolvedCursor(now: now),
              let (column, program) = GuideCursorMotion.program(cursor, in: guide.services)
        else { return String(localized: "番組表") }
        let time = Wording.time(Date(timeIntervalSince1970: Double(program.startAt) / 1000), calendar: GuideLayout.calendar)
        return "\(guide.services[column].name) \(time) \(program.name)"
    }

    /// フォーカスの当たっているマスが枠に入る所まで送る (端に寄せない)
    private func follow(_ cursor: GuideCursor) {
        guard let (column, program) = GuideCursorMotion.program(cursor, in: guide.services),
              let frame = GuideLayout.frame(
                  start: Double(program.startAt),
                  end: Double(program.endAt),
                  rangeStart: from,
                  rangeEnd: to,
                  pointsPerMinute: GuideLayout.tvPointsPerMinute
              )
        else { return }
        let margin = 40.0
        let left = Double(column) * columnStep()
        let right = left + GuideLayout.tvColumnWidth
        let visibleWidth = max(Double(viewport.width) - Double(timeWidth), 1)
        var x = scroll.x
        if left < x + margin {
            x = left - margin
        } else if right > x + visibleWidth - margin {
            x = right - visibleWidth + margin
        }
        var y = scroll.y
        if frame.top < y + margin {
            y = frame.top - margin
        } else if frame.top + frame.height > y + Double(viewport.height) - margin {
            y = frame.top + frame.height - Double(viewport.height) + margin
        }
        scroll = CGPoint(x: clampX(x), y: clampY(y))
    }

    /// 開いたときと、日付・種別を替えたとき。今日ならいまの線が上から 1/4 の所へ送る (3.5)。
    /// カーソルはここで置き、操作しないうちに時刻が進んでも枠が動かないようにする
    private func reset() {
        let now = Date()
        let y = nowOffset(now: now).map {
            GuideLayout.initialScrollOffset(nowOffset: $0, viewportHeight: Double(viewport.height))
        } ?? 0
        scroll = CGPoint(x: 0, y: clampY(y))
        cursor = GuideCursorMotion.initial(in: guide.services, now: Int64(now.timeIntervalSince1970 * 1000))
    }

    private func clampX(_ x: Double) -> Double {
        let visibleWidth = max(Double(viewport.width) - Double(timeWidth), 1)
        return min(max(0, x), max(0, contentWidth - visibleWidth))
    }

    private func clampY(_ y: Double) -> Double {
        min(max(0, y), max(0, totalHeight - Double(viewport.height)))
    }
}

/// 番組表のマス (TV-Guide)。ジャンルの点・`H:mm`・予約の印・番組名・説明。
private struct TVGuideCell: View {
    let item: GuideProgramItem
    let height: Double
    let focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = GuideText.tvCellLines(height: height, dynamicTypeSize: dynamicTypeSize)
        VStack(alignment: .leading, spacing: 4) {
            if lines.title > 0 {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(genreColor)
                        .frame(width: 11, height: 11)
                        // 白地では淡いジャンル色が消えるので、フォーカス中だけ縁を付ける
                        .overlay {
                            if focused {
                                Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1)
                            }
                        }
                        .padding(.top, 11)
                    title
                        // マスの高さ (1 分 4.6pt) から入る行数で行を切るので、題は .callout の段に留める
                        .font(DenpaFont.font(.callout))
                        .foregroundStyle(.primary)
                        .lineLimit(lines.title)
                        .truncationMode(.tail)
                }
            }
            if lines.description > 0, let description = item.description, !description.isEmpty {
                Text(description)
                    // 説明は .caption。行の高さは GuideText が実フォントから取る
                    .font(DenpaFont.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(lines.description)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: GuideLayout.tvColumnWidth, height: height, alignment: .topLeading)
        // フォーカスは純正の設定の行と同じ白い地・黒い字で示す (シアンの枠はやめた)
        .background(focused ? Color.white : background, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: focused ? 12 : 0, y: focused ? 6 : 0)
        .environment(\.colorScheme, focused ? .light : .dark)
    }

    /// 「`H:mm` ✓ 予約済み 番組名」。予約の印は題の行に並べる (TV-Guide の画面案)
    private var title: Text {
        let time = Wording.time(Date(timeIntervalSince1970: Double(item.startAt) / 1000), calendar: GuideLayout.calendar)
        var text = AttributedString("\(time) ")
        for badge in GuideText.cellBadges(reservation: item.reservation) {
            var run = AttributedString("\(mark(of: badge)) ")
            run.foregroundColor = color(of: badge)
            text.append(run)
        }
        text.append(AttributedString(item.name))
        return Text(text)
    }

    /// 録画中は絵のとおり赤い「●」だけにする (iPhone/iPad の「● 録画中」はそのまま)
    private func mark(of badge: GuideCellBadge) -> String {
        badge == .recording ? "●" : badge.text
    }

    private var genreColor: Color {
        guard let rgba = GenreColor.color(item.genre) else { return .secondary }
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    private var background: Color {
        let rgba = GenreColor.cellBackground(item.genre)
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    private func color(of badge: GuideCellBadge) -> Color {
        // フォーカス中は白地になるので、意味のある印も黒に落として読めるようにする
        if focused { return .black }
        return switch badge {
        case .reserved: Color.accentColor
        case .recording: Color.red
        case .conflict: Color.orange
        }
    }
}
