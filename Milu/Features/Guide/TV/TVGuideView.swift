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
        .background(TVTheme.background)
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
                .foregroundStyle(TVTheme.muted)
            Text("denpa に接続できません")
                .font(.system(size: 40, weight: .bold))
                .padding(.top, 10)
            Text("\(app.server?.displayName ?? "") から応答がありません。\nWi-Fi などの接続状況を確認してください。")
                .font(.system(size: 26))
                .foregroundStyle(TVTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button("再試行") {
                Task { await model.reload() }
            }
            .font(.system(size: 26, weight: .semibold))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 300)
    }
}

/// 番組表の格子と上の段。格子のフォーカスは列ごとの的が持ち、どのマスを選ぶかは
/// 1 つのカーソル (`GuideCursor`) で決める。送りは自前 (格子の中の位置を決め打ちで動かす) なので、
/// 見えている分だけを作る。
private struct TVGuideBoard: View {
    let guide: GuideResponse
    let model: GuideModel
    let onOpen: (GuideProgramItem) -> Void

    private static let headerHeight = 64.0

    private enum Focus: Hashable {
        case type(ServiceType)
        case day(Date)
        case column(Int)
    }

    @FocusState private var focus: Focus?
    /// いま選んでいるマス。読み直しで消えたら `resolvedCursor` が作り直す
    @State private var cursor: GuideCursor?
    /// 最後に焦点の当たっていた列。的が消えると focus が nil に落ちるので、直すときの手掛かりに持つ
    @State private var lastColumn: Int?
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
        // 読み直しで焦点の列が使えなくなったら (番組が消えた・局が減った)、近い列へ移す
        .onChange(of: guide.services) { _, services in
            repairFocus(services, now: Date())
        }
        // 焦点が列に移ったら、基準の時刻でその列の番組を選ぶ。左右の移動はこれだけで決める
        .onChange(of: focus) { _, new in
            switch new {
            case .some(.column(let column)):
                lastColumn = column
            case .some:
                // 自分で格子の外 (チップ) へ出た。直す対象ではない
                lastColumn = nil
            case .none:
                // サイドバー・詳細など。的が消えて落ちた場合に備えて最後の列を残す
                break
            }
            guard case .column(let column) = new, let base = resolvedCursor(now: Date()) else { return }
            let next = GuideCursorMotion.horizontal(base, in: guide.services, by: column - base.column) ?? base
            cursor = next
            follow(next, in: guide.services)
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
    /// 選んでいるものだけ tint で塗り、フォーカスと区別できるようにする
    private func chip(
        _ label: String,
        active: Bool,
        focus value: Focus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: active ? .bold : .medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // 未選択は tint を外す。.secondary を渡すとフォーカス時に選択中と同じ灰の面に白字になる
        .tint(active ? Color.accentColor : nil)
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
                                .font(.system(size: 21))
                                .foregroundStyle(TVTheme.muted)
                        }
                        Text(service.name)
                            .font(DenpaFont.font(size: 25))
                            .bold()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: GuideLayout.tvColumnWidth, height: Self.headerHeight, alignment: .leading)
                }
            }
            .offset(x: GuideLayout.tvTimeWidth - scroll.x)
        }
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
        .clipped()
    }

    private func grid(size: CGSize, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            columns(size: size, now: now)
                .offset(x: GuideLayout.tvTimeWidth - scroll.x, y: -scroll.y)
                .accessibilityHidden(true)
            timeColumn(now: now)
                .offset(y: -scroll.y)
                .accessibilityHidden(true)
            focusTargets(size: size, now: now)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
    }

    /// 列ごとのフォーカスの的 (見た目は出さない)。格子を 1 つの的にすると tvOS からは隣の列が
    /// 見えず、左を押すと格子の外 (サイドバー) へ焦点が抜ける。的を列ごとに置けば格子の中で移る。
    /// Button をやめた (tvOS 26/27 では Button に focusEffectDisabled を付けても格子を囲む縁が
    /// 消えないため) ので、押せることと決定の動きはここで持つ。青枠は格子の中に自前で描く
    private func focusTargets(size: CGSize, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(columnRange(size: size)), id: \.self) { column in
                let usable = !guide.services[column].programs.isEmpty
                Color.clear
                    .frame(width: GuideLayout.tvColumnWidth, height: size.height)
                    .contentShape(Rectangle())
                    // 焦点が当たっている列は、読み直しで番組が消えても的を残す。的が無くなると
                    // focus が nil になり、格子がどの押下にも応えなくなる (repairFocus が移すまでの間)
                    .focusable(usable || focus == .column(column))
                    .focusEffectDisabled()
                    .focused($focus, equals: .column(column))
                    .onMoveCommand { move($0) }
                    // 番組の無い列はタップの当たりも付けない (決定しても開くものが無い)
                    .gesture(TapGesture().onEnded { open(column: column, now: now) }, including: usable ? .all : .none)
                    // 列は 1 つのまとまりなので、読み上げはその列で選んでいる番組だけにする
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(cursorLabel(column: column, now: now))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open(column: column, now: now) }
                    // 番組の無い列は読み上げない (決定しても開くものが無い)
                    .accessibilityHidden(!usable)
                    .offset(x: GuideLayout.tvTimeWidth + Double(column) * columnStep() - scroll.x)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// マス・過ぎた所の黒・いまの線。見えている範囲と前後だけを作る
    private func columns(size: CGSize, now: Date) -> some View {
        let rows = rowRange(size: size)
        let nowY = nowOffset(now: now)
        let selected = resolvedCursor(now: now)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(columnRange(size: size)), id: \.self) { column in
                let focused = focus == .column(column) ? selected?.programID : nil
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(TVTheme.muted)
                    .offset(y: GuideLayout.offset(of: time, from: from, pointsPerMinute: GuideLayout.tvPointsPerMinute) + 6)
            }
            if let nowY = nowOffset(now: now) {
                Text("\(GuideLayout.calendar.component(.minute, from: now))")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .offset(y: nowY - 14)
            }
        }
        .frame(width: GuideLayout.tvTimeWidth, height: totalHeight, alignment: .topLeading)
        .background(TVTheme.background)
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

    /// いまのカーソル。読み直しで番組が消えていたら、焦点の列 (無ければ最後に焦点のあった列) で
    /// 作り直し、その列も使えなければ近い列へ寄せる (先頭の局・いまの時刻へは跳ばさない)
    private func resolvedCursor(now: Date) -> GuideCursor? {
        if let cursor, GuideCursorMotion.program(cursor, in: guide.services) != nil {
            return cursor
        }
        let time = Int64(now.timeIntervalSince1970 * 1000)
        let anchor = cursor?.anchor ?? time
        if let column = lastColumn ?? focusColumn {
            if let rebuilt = GuideCursorMotion.cursor(at: column, anchor: anchor, in: guide.services) {
                return rebuilt
            }
            if let fallback = GuideCursorMotion.fallbackCursor(from: column, anchor: anchor, in: guide.services) {
                return fallback
            }
        }
        return GuideCursorMotion.initial(in: guide.services, now: time)
    }

    /// 焦点が列にあるときのその列
    private var focusColumn: Int? {
        if case .column(let column) = focus { return column }
        return nil
    }

    /// 読み直しで焦点の列が使えなくなったら、近い列へ寄せる。的が消えた列に留まると cursor と
    /// 食い違って格子が無反応になる。focus は的が消えた時点で nil に落ち得るので、判断は最後に
    /// 焦点のあった列 (`lastColumn`) でする。focus を移すのは格子が焦点を持っているときだけで、
    /// サイドバー・詳細・チップの焦点は利用者のものなので触らない
    private func repairFocus(_ services: [GuideService], now: Date) {
        guard let column = lastColumn ?? focusColumn,
              !GuideCursorMotion.isUsable(column, in: services)
        else { return }
        let anchor = cursor?.anchor ?? Int64(now.timeIntervalSince1970 * 1000)
        guard let target = GuideCursorMotion.fallbackCursor(from: column, anchor: anchor, in: services) else {
            cursor = nil
            lastColumn = nil
            return
        }
        cursor = target
        lastColumn = target.column
        follow(target, in: services)
        if focusColumn != nil {
            focus = .column(target.column)
        }
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

    /// 上下だけを持つ。左右は tvOS の焦点の仕組み (列ごとの的) が動かし、青枠は焦点の移りで決める
    private func move(_ direction: MoveCommandDirection) {
        // 焦点が既にチップなどへ抜けていれば、見えないカーソルを動かさない
        guard direction == .up || direction == .down,
              let current = resolvedCursor(now: Date()),
              focus == .column(current.column)
        else { return }
        if let next = GuideCursorMotion.vertical(current, in: guide.services, by: direction == .up ? -1 : 1) {
            cursor = next
            follow(next, in: guide.services)
        } else if direction == .up {
            // 一番上の番組からは、上の段 (日付) へ抜ける
            focus = .day(model.selectedDay)
        }
    }

    /// その列で選ぶ番組 (基準の時刻から)
    private func program(column: Int, now: Date) -> GuideProgramItem? {
        guard let base = resolvedCursor(now: now),
              let cursor = GuideCursorMotion.cursor(at: column, anchor: base.anchor, in: guide.services),
              let (c, program) = GuideCursorMotion.program(cursor, in: guide.services)
        else { return nil }
        return GuideProgramItem(service: guide.services[c], program: program)
    }

    /// 決定。焦点の列 (タップした列) の番組を開く
    private func open(column: Int, now: Date) {
        guard let item = program(column: column, now: now) else { return }
        onOpen(item)
    }

    /// 読み上げる字 (その列で選んでいるマス)
    private func cursorLabel(column: Int, now: Date) -> String {
        guard let item = program(column: column, now: now) else { return String(localized: "番組表") }
        let time = Wording.time(Date(timeIntervalSince1970: Double(item.startAt) / 1000), calendar: GuideLayout.calendar)
        return "\(item.serviceName) \(time) \(item.name)"
    }

    /// フォーカスの当たっている列を枠に入れ、その左右の次の列 (番組のある列) を少し見える所まで
    /// 横に送る。tvOS の焦点はクリップの外の的へは移れないので、次へ移れる分を先に出しておく。
    /// 縦は基準の時刻が画面に残る所まで送る (マスの端に合わせると、横に動くたび時刻が揺れる)
    private func follow(_ cursor: GuideCursor, in services: [GuideService]) {
        let column = cursor.column
        guard GuideCursorMotion.isUsable(column, in: services) else { return }
        let margin = 40.0
        let visibleWidth = max(Double(viewport.width) - GuideLayout.tvTimeWidth, 1)
        var x = scroll.x
        let left = Double(column) * columnStep()
        let right = left + GuideLayout.tvColumnWidth
        if left < x + margin {
            x = left - margin
        } else if right > x + visibleWidth - margin {
            x = right - visibleWidth + margin
        }
        // 次に移る列を margin だけ見せる
        if let next = GuideCursorMotion.adjacentColumn(from: column, in: services, by: 1),
           Double(next) * columnStep() > x + visibleWidth - margin {
            x = Double(next) * columnStep() - visibleWidth + margin
        }
        if let previous = GuideCursorMotion.adjacentColumn(from: column, in: services, by: -1),
           Double(previous) * columnStep() + GuideLayout.tvColumnWidth < x + margin {
            x = Double(previous) * columnStep() + GuideLayout.tvColumnWidth - margin
        }
        let anchorY = GuideLayout.offset(
            of: Double(cursor.anchor),
            from: from,
            pointsPerMinute: GuideLayout.tvPointsPerMinute
        )
        var y = scroll.y
        if anchorY < y + margin {
            y = anchorY - margin
        } else if anchorY > y + Double(viewport.height) - margin {
            y = anchorY - Double(viewport.height) + margin
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
        let visibleWidth = max(Double(viewport.width) - GuideLayout.tvTimeWidth, 1)
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

    var body: some View {
        let lines = GuideText.tvCellLines(height: height)
        VStack(alignment: .leading, spacing: 4) {
            if lines.title > 0 {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(genreColor)
                        .frame(width: 11, height: 11)
                        .padding(.top, 11)
                    title
                        .font(DenpaFont.font(size: 25))
                        .foregroundStyle(.primary)
                        .lineLimit(lines.title)
                        .truncationMode(.tail)
                }
            }
            if lines.description > 0, let description = item.description, !description.isEmpty {
                Text(description)
                    .font(DenpaFont.font(size: 21))
                    .foregroundStyle(TVTheme.muted)
                    .lineLimit(lines.description)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: GuideLayout.tvColumnWidth, height: height, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 5)
            }
        }
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
        guard let rgba = GenreColor.color(item.genre) else { return TVTheme.muted }
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    private var background: Color {
        let rgba = GenreColor.cellBackground(item.genre)
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    private func color(of badge: GuideCellBadge) -> Color {
        switch badge {
        case .reserved: Color.accentColor
        case .recording: Color.red
        case .conflict: Color.orange
        }
    }
}
