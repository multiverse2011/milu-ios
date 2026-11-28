import SwiftUI

/// tvOS の番組表 (TV-Guide)。上の段に 種別・日付、その下に局の行と格子。
/// マスはフォーカスで動き、決定で番組の詳細 (TV-Program) を全画面で開く。
struct TVGuideView: View {
    let model: GuideModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if model.didFail, model.guide == nil {
                unavailable
            } else if let guide = model.guide {
                TVGuideBoard(guide: guide, model: model)
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
    @Environment(AppModel.self) private var app
    @ScaledMetric(relativeTo: .body) private var textScale: Double = 1

    private static let headerHeight = 64.0
    /// 送りの動き。tvOS の焦点移動に近い短い easeOut
    private static let moveAnimation = Animation.easeOut(duration: 0.25)

    private enum Focus: Hashable {
        case type(ServiceType)
        case day(Date)
        case column(Int)
        case aboveGrid
        case columnEdge(ColumnEdge)
    }

    private enum ColumnEdge: Hashable {
        case left, right

        var step: Int { self == .left ? -1 : 1 }
    }

    @FocusState private var focus: Focus?
    /// いま選んでいるマス。読み直しで消えたら `resolvedCursor` が作り直す
    @State private var cursor: GuideCursor?
    /// 最後に焦点の当たっていた列。的が消えると focus が nil に落ちるので、直すときの手掛かりに持つ
    @State private var lastColumn: Int?
    @State private var opened: GuideProgramItem?
    @State private var detailGeneration = 0
    @State private var isDetailCoverActive = false
    @State private var isRestoringDetailFocus = false
    @State private var liveWatchAtOpen: AppModel.LiveWatchRequest?
    @State private var scroll = CGPoint.zero
    /// 動きの連鎖中に出した送り先の最小・最大。動いている間はこの範囲と現在地の両方の列・行を作る
    /// (逆向きに割り込まれても、途中の描画位置がこの範囲の外へ出ないように)
    @State private var scrollLow = CGPoint.zero
    @State private var scrollHigh = CGPoint.zero
    /// 動きの通し番号。割り込まれた動きの完了では範囲を畳まない (連打で範囲が狭まらないように)
    @State private var animationToken = 0
    /// 動きの連鎖が続いているか。範囲を畳むのは連鎖が終わったときだけ
    @State private var isAnimating = false
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
        let generation = detailGeneration
        // いまの線を 1 分ごとに動かす (iPhone の GuideGrid と同じ)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .background {
            // 番組表の identity を保ち、カバーの通知だけを開いた回に結び付ける。
            Color.clear
                .fullScreenCover(item: detailPresentation(generation), onDismiss: { detailDidDismiss(generation) }) { item in
                    TVProgramView(item: item, model: model, onClose: { closeDetail(generation) })
                }
                .id(generation)
        }
        .onAppear {
            // ライブへのタブ切り替えで onDismiss が届かなかった場合も、戻ったら詳細を開けるようにする。
            guard isDetailCoverActive, liveWatchAtOpen != app.liveWatch else { return }
            opened = nil
            isDetailCoverActive = false
            isRestoringDetailFocus = false
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
            let target = CGPoint(x: clampX(scroll.x), y: scroll.y)
            // 走っている動きを止められるのは送り先が変わるときだけ。同じ値のまま範囲だけ
            // 畳むと、残りの動きで作られていない列・行が出る (マスが欠ける)
            guard target != scroll || !isAnimating else { return }
            withAnimation(nil) {
                scroll = target
                scrollLow = target
                scrollHigh = target
            }
        }
        // 読み直しで選んだ番組や局が消えたら、カーソルと送りをそろえ直す
        .onChange(of: guide.services) { _, services in
            repairFocus(services, now: Date())
        }
        // 列への直接移動と、格子の外にある隣の列への移動を焦点の遷移で扱う。
        .onChange(of: focus) { old, new in
            // 詳細の出入りで一時的に当たったチップや列を、カーソルの移動に使わない。
            guard opened == nil else { return }
            if case .columnEdge(let edge) = new {
                if case .column(let column) = old {
                    moveAcrossColumnEdge(edge, from: column)
                }
                return
            }
            guard case .column(let column) = new else {
                if case .column(let previous) = old, case .some = new {
                    moveUp(from: previous)
                    return
                }
                // サイドバー (nil) へ移った場合は、入り直す列を覚えておく。
                if case .some = new { lastColumn = nil }
                return
            }
            // チップやサイドバーから格子へ入り直したときは、いた列 (カーソルの列) へ戻す。
            // 焦点の仕組みはチップの真下の列を選ぶので、そのままだと別の局へ飛んで見える。
            // 離れている間にデータが変わっていても合うよう、送りを即座にそろえてから焦点を渡す
            if case .some(.column) = old {} else if let base = cursor, base.column != column,
                      GuideCursorMotion.isUsable(base.column, in: guide.services) {
                follow(base, in: guide.services, animated: false)
                focus = .column(base.column)
                return
            }
            isRestoringDetailFocus = false
            lastColumn = column
            guard let base = resolvedCursor(now: Date()) else { return }
            let next = GuideCursorMotion.horizontal(base, in: guide.services, by: column - base.column) ?? base
            animate(to: next, in: guide.services)
        }
    }

    /// 列の真上に受け口を置くと、チップの真下にない列でも ↑ がサイドバーへ向かわない。
    /// 格子にいる間だけ有効にし、左右の移動やチップからの入り直しは tvOS に任せる。
    private func upperFocusTarget(width: Double) -> some View {
        Color.clear
            .frame(
                width: min(contentWidth, max(0, width - GuideLayout.tvTimeWidth)),
                height: Self.headerHeight
            )
            .contentShape(Rectangle())
            .focusable(opened == nil && (focusColumn != nil || focus == .aboveGrid))
            .focusEffectDisabled()
            .focused($focus, equals: .aboveGrid)
            .accessibilityHidden(true)
            .offset(x: GuideLayout.tvTimeWidth)
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
            upperFocusTarget(width: width)
        }
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
        .clipped()
    }

    private func grid(size: CGSize, now: Date) -> some View {
        let rows = rowRange(size: size)
        let gridCells = columnRange(size: size).map { column in
            (column: column, cells: cells(in: column, rows: rows))
        }
        let selected = resolvedCursor(now: now)
        // 格子の端の的を経由する間は強調を保つ。詳細を閉じる間は格子に焦点が戻るまで表示しない。
        let highlightedColumn = switch focus {
        case .aboveGrid, .columnEdge: lastColumn
        default: focusColumn
        }
        let focused = opened == nil && !isRestoringDetailFocus && selected?.column == highlightedColumn ? selected : nil
        let nowY = nowOffset(now: now)
        let ring = focusFrame(for: focused)
        let ruler = timeColumn(now: now, nowY: nowY)
        return ZStack(alignment: .topLeading) {
            GuideGridScroll(scrollY: scroll.y) { scrollY in
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        columns(gridCells, height: size.height, nowY: nowY, focused: focused, scrollY: scrollY)
                            .transaction { $0.animation = nil }
                        if let ring {
                            // 枠自身の座標と高さは、送りとは別に補間する。
                            GuideFocusRing(rect: ring, scrollY: scrollY)
                                .fill(Color.accentColor, style: FillStyle(eoFill: true))
                                .allowsHitTesting(false)
                        }
                        if let nowY {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: contentWidth, height: 2)
                                .offset(y: nowY - scrollY)
                                .transaction { $0.animation = nil }
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
                    .offset(x: GuideLayout.tvTimeWidth - scroll.x)
                    ruler
                        .offset(y: -scrollY)
                        .transaction { $0.animation = nil }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .accessibilityHidden(true)
            }
            focusTargets(size: size, now: now)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .overlay(alignment: .topLeading) {
            // 左は時刻列の中、右は格子の外側の 40 pt の余白に置く。選択列の的とは重ねない。
            ZStack(alignment: .topLeading) {
                columnEdgeTarget(.left, size: size)
                columnEdgeTarget(.right, size: size)
            }
        }
    }

    private func columnEdgeTarget(_ edge: ColumnEdge, size: CGSize) -> some View {
        let width = 24.0
        let timeWidth = GuideLayout.tvTimeWidth
        let visibleWidth = Double(size.width) - timeWidth
        let hiddenNeighbor = focusColumn
            .flatMap { GuideCursorMotion.adjacentColumn(from: $0, in: guide.services, by: edge.step) }
            .map { !GuideLayout.tvColumnIsVisible($0, scrollX: scroll.x, visibleWidth: visibleWidth) } ?? false
        let target = Focus.columnEdge(edge)
        return Color.clear
            .frame(width: width, height: size.height)
            .contentShape(Rectangle())
            .focusable(opened == nil && visibleWidth > 0 && (hiddenNeighbor || focus == target))
            .focusEffectDisabled()
            .focused($focus, equals: target)
            .accessibilityHidden(true)
            .offset(x: edge == .left ? timeWidth - width : Double(size.width))
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
                    // 決定。番組の無い列は当たりを付けない (決定しても開くものが無い)
                    .modifier(FocusTap(enabled: usable) { open(column: column, now: now) })
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

    /// マス・過ぎた所の黒・いまの線・青枠。見えている範囲と前後だけを作る
    private func columns(
        _ gridCells: [(column: Int, cells: [Cell])], height: Double,
        nowY: Double?, focused: GuideCursor?, scrollY: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(gridCells, id: \.column) { column, cells in
                ForEach(cells, id: \.item.id) { cell in
                    let top = cell.top + GuideLayout.tvColumnGap / 2
                    TVGuideCell(
                        item: cell.item,
                        title: cell.title,
                        height: max(cell.height - GuideLayout.tvColumnGap, 2),
                        viewportTop: scrollY - top,
                        viewportHeight: height,
                        textScale: textScale
                    )
                        .offset(x: Double(column) * columnStep(), y: top - scrollY)
                        // フォーカス中のマスは過ぎた所の黒より上に描く (画面案の z の順)
                        .zIndex(focused?.column == column && focused?.programID == cell.item.id ? 1 : 0)
                }
            }
            if let nowY {
                // 過ぎた所はマスの上に重ねる (画面案の z)。当たりは取らない
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: contentWidth, height: nowY)
                    .offset(y: -scrollY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
    }

    /// 青枠の位置 (フォーカスの当たっているマス)。焦点の列とカーソルの列がそろっているときだけ出す
    private func focusFrame(for cursor: GuideCursor?) -> CGRect? {
        guard let cursor,
              let (column, program) = GuideCursorMotion.program(cursor, in: guide.services),
              let frame = GuideLayout.frame(
                  start: Double(program.startAt),
                  end: Double(program.endAt),
                  rangeStart: from,
                  rangeEnd: to,
                  pointsPerMinute: GuideLayout.tvPointsPerMinute
              )
        else { return nil }
        return CGRect(
            x: Double(column) * columnStep(),
            y: frame.top + GuideLayout.tvColumnGap / 2,
            width: GuideLayout.tvColumnWidth,
            height: max(frame.height - GuideLayout.tvColumnGap, 2)
        )
    }

    /// 時刻の列。時の数字と、いまの線の左に出す分 (TV-Guide の画面案)。
    /// 地の色で塗って切り取る (横に送ったマスがここへ潜り込まないように)
    private func timeColumn(now: Date, nowY: Double?) -> some View {
        let start = from
        let hours = (0..<24).map { hour in
            let time = start + Double(hour) * 3_600_000
            let date = Date(timeIntervalSince1970: time / 1000)
            let label = Text("\(GuideLayout.calendar.component(.hour, from: date))")
            let y = GuideLayout.offset(of: time, from: start, pointsPerMinute: GuideLayout.tvPointsPerMinute) + 6
            return (hour: hour, label: label, y: y)
        }
        let minute = nowY.map { _ in Text("\(GuideLayout.calendar.component(.minute, from: now))") }
        return ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.hour) { hour in
                hour.label
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(TVTheme.muted)
                    .offset(y: hour.y)
            }
            if let nowY, let minute {
                minute
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
        let time = Int64(now.timeIntervalSince1970 * 1000)
        let anchor = cursor?.anchor ?? time
        if let column = lastColumn ?? focusColumn ?? cursor?.column {
            return GuideCursorMotion.repairedCursor(cursor, from: column, anchor: anchor, in: guide.services)
        }
        return GuideCursorMotion.initial(in: guide.services, now: time)
    }

    /// 焦点が列にあるときのその列
    private var focusColumn: Int? {
        if case .column(let column) = focus { return column }
        return nil
    }

    /// 読み直しで選んだ番組が消えたら、同じ列か近い列の番組を選び直して送る。
    /// 的が消えると focus が nil に落ち得るので、最後に焦点のあった列も使う。
    /// サイドバー・詳細・チップに焦点がある間は、カーソルと送りだけを直す。
    private func repairFocus(_ services: [GuideService], now: Date) {
        guard let column = lastColumn ?? focusColumn ?? cursor?.column else { return }
        let anchor = cursor?.anchor ?? Int64(now.timeIntervalSince1970 * 1000)
        let target = GuideCursorMotion.repairedCursor(cursor, from: column, anchor: anchor, in: services)
        guard target != cursor || (target == nil && lastColumn != nil) else { return }
        // アニメーション中に読み直しが来ても、カーソルの付け替えは即座にする
        withAnimation(nil) {
            cursor = target
            lastColumn = target?.column
        }
        guard let target else { return }
        follow(target, in: services, animated: false)
        if focusColumn != nil, opened == nil {
            focus = .column(target.column)
        }
    }

    // MARK: 作る範囲

    private func columnStep() -> Double {
        GuideLayout.tvColumnWidth + GuideLayout.tvColumnGap
    }

    /// 作る列。動いている間は連鎖中に出した送り先の範囲 (と現在地) を作る
    private func columnRange(size: CGSize) -> Range<Int> {
        let count = guide.services.count
        let first = GuideLayout.tvColumnRange(scrollX: min(scroll.x, scrollLow.x), width: Double(size.width), count: count)
        let last = GuideLayout.tvColumnRange(scrollX: max(scroll.x, scrollHigh.x), width: Double(size.width), count: count)
        return first.lowerBound..<last.upperBound
    }

    /// 作る行。動いている間は連鎖中に出した送り先の範囲 (と現在地) を作る
    private func rowRange(size: CGSize) -> ClosedRange<Double> {
        let margin = 300.0
        return max(0, min(scroll.y, scrollLow.y) - margin)...(max(scroll.y, scrollHigh.y) + Double(size.height) + margin)
    }

    private typealias Cell = (item: GuideProgramItem, title: AttributedString, top: Double, height: Double)

    private func cells(in column: Int, rows: ClosedRange<Double>) -> [Cell] {
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
            let item = GuideProgramItem(service: service, program: program)
            return (item, TVGuideCell.title(for: item), frame.top, frame.height)
        }
    }

    // MARK: フォーカスと送り

    /// 上は列から上の的へ焦点が移ったときだけ処理する。
    private func moveUp(from column: Int) {
        if let base = resolvedCursor(now: Date()),
           let current = GuideCursorMotion.selectedCursor(inColumn: column, from: base, in: guide.services),
           let up = GuideCursorMotion.vertical(current, in: guide.services, by: -1) {
            lastColumn = column
            animate(to: up, in: guide.services)
            focus = .column(column)
        } else {
            lastColumn = nil
            if focus == .aboveGrid {
                focus = model.menuDays.contains(model.selectedDay) ? .day(model.selectedDay) : .type(model.selectedType)
            }
        }
    }

    /// 画面外の隣の列を先に表示し、見えるようになってから焦点を渡す。
    private func moveAcrossColumnEdge(_ edge: ColumnEdge, from column: Int) {
        guard let base = resolvedCursor(now: Date()),
              let current = GuideCursorMotion.selectedCursor(inColumn: column, from: base, in: guide.services),
              let next = GuideCursorMotion.horizontal(current, in: guide.services, by: edge.step)
        else {
            focus = GuideCursorMotion.isUsable(column, in: guide.services) ? .column(column) : nil
            return
        }
        lastColumn = next.column
        animate(to: next, in: guide.services) {
            guard focus == .columnEdge(edge), opened == nil else { return }
            focus = resolvedCursor(now: Date()).map { .column($0.column) }
        }
    }

    /// 下だけを持つ。左右は tvOS の焦点の仕組み (列または格子の端の的) が動かす。
    private func move(_ direction: MoveCommandDirection) {
        // 焦点が既にチップなどへ抜けていれば、見えないカーソルを動かさない
        guard direction == .down, opened == nil,
              let current = resolvedCursor(now: Date()),
              focus == .column(current.column)
        else { return }
        if let next = GuideCursorMotion.vertical(current, in: guide.services, by: 1) {
            animate(to: next, in: guide.services)
        }
    }

    /// 焦点の移動に合わせて、表と青枠を滑らかに送る。連打では前の動きを打ち切って次へ向かう
    /// (アニメーションは溜まらない)。動いている間は、連鎖中に出した送り先の範囲を列・行に作る
    private func animate(to cursor: GuideCursor, in services: [GuideService], completion: (() -> Void)? = nil) {
        // 何も動かない (読み直しの後始末や、同じ所へ入り直しただけ) なら動きを始めない
        let target = followTarget(cursor, in: services)
        guard cursor != self.cursor || (target != nil && target != scroll) else {
            completion?()
            return
        }
        if !isAnimating {
            scrollLow = scroll
            scrollHigh = scroll
        }
        isAnimating = true
        animationToken += 1
        let token = animationToken
        withAnimation(Self.moveAnimation) {
            self.cursor = cursor
            follow(cursor, in: services, animated: true)
        } completion: {
            guard animationToken == token else { return }
            isAnimating = false
            scrollLow = scroll
            scrollHigh = scroll
            completion?()
        }
    }

    /// その列で選ぶ番組 (焦点の列はいま強調しているマス)
    private func selection(column: Int, now: Date) -> (cursor: GuideCursor, item: GuideProgramItem)? {
        guard let base = resolvedCursor(now: now),
              let cursor = GuideCursorMotion.selectedCursor(inColumn: column, from: base, in: guide.services),
              let (c, program) = GuideCursorMotion.program(cursor, in: guide.services)
        else { return nil }
        return (cursor, GuideProgramItem(service: guide.services[c], program: program))
    }

    /// 決定。焦点の列 (タップした列) の番組を開く
    private func open(column: Int, now: Date) {
        guard !isDetailCoverActive, let selection = selection(column: column, now: now) else { return }
        cursor = selection.cursor
        lastColumn = column
        liveWatchAtOpen = app.liveWatch
        isRestoringDetailFocus = false
        isDetailCoverActive = true
        detailGeneration += 1
        opened = selection.item
    }

    /// Menu をシステムが処理してカバーを閉じる場合も、同じ閉じ始めの処理を通す。
    private func detailPresentation(_ generation: Int) -> Binding<GuideProgramItem?> {
        Binding(get: { detailGeneration == generation ? opened : nil }, set: { item in
            if item == nil { closeDetail(generation) }
        })
    }

    private func closeDetail(_ generation: Int) {
        guard detailGeneration == generation, opened != nil else { return }
        opened = nil
        // 「ライブで観る」でタブを移ったときは、その画面に焦点を渡す。
        guard liveWatchAtOpen == app.liveWatch else { return }
        isRestoringDetailFocus = true
        DispatchQueue.main.async {
            restoreDetailFocus(generation)
        }
    }

    private func detailDidDismiss(_ generation: Int) {
        guard detailGeneration == generation, isDetailCoverActive else { return }
        closeDetail(generation)
        isDetailCoverActive = false
        // 閉じ始めの要求がまだ通っていなければ、カバーが外れた時点でもう一度要求する。
        restoreDetailFocus(generation)
    }

    private func restoreDetailFocus(_ generation: Int) {
        guard detailGeneration == generation, isRestoringDetailFocus, liveWatchAtOpen == app.liveWatch,
              let target = resolvedCursor(now: Date()) else { return }
        cursor = target
        lastColumn = target.column
        follow(target, in: guide.services, animated: false)
        let destination = Focus.column(target.column)
        if focus == destination {
            isRestoringDetailFocus = false
        } else {
            focus = destination
        }
    }

    /// 読み上げる字 (その列で選んでいるマス)
    private func cursorLabel(column: Int, now: Date) -> String {
        guard let item = selection(column: column, now: now)?.item else { return String(localized: "番組表") }
        let time = Wording.time(Date(timeIntervalSince1970: Double(item.startAt) / 1000), calendar: GuideLayout.calendar)
        return "\(item.serviceName) \(time) \(item.name)"
    }

    /// フォーカスの当たっている列を枠に入れ、その左右の次の列 (番組のある列) を少し見える所まで
    /// 横に送る。tvOS の焦点はクリップの外の的へは移れないので、次へ移れる分を先に出しておく。
    /// 縦は基準の時刻と、画面内に寄せた見出しが読める所まで送る。
    /// 動かせない列なら `nil`
    private func followTarget(_ cursor: GuideCursor, in services: [GuideService]) -> CGPoint? {
        let column = cursor.column
        guard GuideCursorMotion.isUsable(column, in: services) else { return nil }
        let visibleWidth = max(Double(viewport.width) - GuideLayout.tvTimeWidth, 1)
        let x = GuideLayout.tvFollowColumnOffset(
            scrollX: scroll.x, visibleWidth: visibleWidth, column: column,
            previous: GuideCursorMotion.adjacentColumn(from: column, in: services, by: -1),
            next: GuideCursorMotion.adjacentColumn(from: column, in: services, by: 1)
        )
        let anchorY = GuideLayout.offset(
            of: Double(cursor.anchor),
            from: from,
            pointsPerMinute: GuideLayout.tvPointsPerMinute
        )
        var cell: ClosedRange<Double>?
        var headingHeight = 0.0
        if let (_, program) = GuideCursorMotion.program(cursor, in: services),
           let frame = GuideLayout.frame(
               start: Double(program.startAt), end: Double(program.endAt),
               rangeStart: from, rangeEnd: to, pointsPerMinute: GuideLayout.tvPointsPerMinute
           ) {
            let top = frame.top + GuideLayout.tvColumnGap / 2
            let height = max(frame.height - GuideLayout.tvColumnGap, 2)
            cell = top...(top + height)
            let lines = GuideText.tvCellLines(height: height, textScale: textScale)
            headingHeight = GuideText.tvCellHeadingHeight(titleLines: lines.title, textScale: textScale)
        }
        let y = GuideLayout.tvFollowOffset(
            scrollY: scroll.y, viewportHeight: Double(viewport.height), anchorY: anchorY,
            cell: cell, headingHeight: headingHeight
        )
        return CGPoint(x: clampX(x), y: clampY(y))
    }

    /// 送る。`animated` が false のときは即座に送り、動きの範囲も畳む (開いたとき・後始末)。
    /// 動いている最中に送り先が同じなら、何もしない (範囲だけ畳むとマスが欠ける)
    private func follow(_ cursor: GuideCursor, in services: [GuideService], animated: Bool) {
        guard let target = followTarget(cursor, in: services) else { return }
        if animated {
            // 連鎖中に出した送り先の最小・最大を覚える (逆向きに割り込まれても描画位置が外へ出ない)
            scrollLow = CGPoint(x: min(scrollLow.x, target.x), y: min(scrollLow.y, target.y))
            scrollHigh = CGPoint(x: max(scrollHigh.x, target.x), y: max(scrollHigh.y, target.y))
            scroll = target
        } else if target != scroll || !isAnimating {
            // 走っている動きを止められるのは送り先が変わるときだけ。同じ値のまま範囲だけ
            // 畳むと、残りの動きで作られていない列・行が出る (マスが欠ける)
            withAnimation(nil) {
                isAnimating = false
                scrollLow = target
                scrollHigh = target
                scroll = target
            }
        }
    }

    /// 開いたときと、日付・種別を替えたとき。今日ならいまの線が上から 1/4 の所へ送る (3.5)。
    /// カーソルはここで置き、操作しないうちに時刻が進んでも枠が動かないようにする。
    /// ここは動かさない (即座に置き直す)
    private func reset() {
        let now = Date()
        let y = nowOffset(now: now).map {
            GuideLayout.initialScrollOffset(nowOffset: $0, viewportHeight: Double(viewport.height))
        } ?? 0
        let target = CGPoint(x: 0, y: clampY(y))
        // アニメーション中でも確実に止めて即座に置き直す
        withAnimation(nil) {
            scroll = target
            isAnimating = false
            scrollLow = target
            scrollHigh = target
            cursor = GuideCursorMotion.initial(in: guide.services, now: Int64(now.timeIntervalSince1970 * 1000))
        }
    }

    private func clampX(_ x: Double) -> Double {
        let visibleWidth = max(Double(viewport.width) - GuideLayout.tvTimeWidth, 1)
        return min(max(0, x), max(0, contentWidth - visibleWidth))
    }

    private func clampY(_ y: Double) -> Double {
        min(max(0, y), max(0, totalHeight - Double(viewport.height)))
    }
}

/// 送りの途中で追加されたマスも、格子のほかの要素と同じ縦位置を使う。
private struct GuideGridScroll<Content: View>: View, Animatable {
    var scrollY: Double
    let content: (Double) -> Content

    var animatableData: Double {
        get { scrollY }
        set { scrollY = newValue }
    }

    var body: some View {
        content(scrollY)
    }
}

/// 格子内の枠だけを補間し、現在の送り位置を描画時に引く。
private nonisolated struct GuideFocusRing: Shape {
    var rect: CGRect
    let scrollY: Double

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData> {
        get { AnimatablePair(rect.origin.animatableData, rect.size.animatableData) }
        set {
            rect.origin.animatableData = newValue.first
            rect.size.animatableData = newValue.second
        }
    }

    func path(in bounds: CGRect) -> Path {
        let frame = rect.offsetBy(dx: 0, dy: -scrollY)
        var path = Path(roundedRect: frame, cornerRadius: 6)
        let inside = frame.insetBy(dx: 5, dy: 5)
        if !inside.isEmpty {
            path.addRoundedRect(in: inside, cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

/// 決定の当たり。番組の無い列は何もしない (決定しても開くものが無い)。
/// 再生の面と同じく `.onTapGesture` で受ける (実機の決定で動いている書き方)。
/// 当たりを条件で付け分けると、番組の有無が変わったときに的のビューが作り直されて
/// 焦点が落ちるので、いつも付け、空列は中で返す
private struct FocusTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onTapGesture {
            guard enabled else { return }
            action()
        }
    }
}

/// 番組表のマス (TV-Guide)。ジャンルの点・`H:mm`・予約の印・番組名・説明。
/// 青枠は格子に 1 つだけ置いて動かす (columns) ので、マスは地と字だけを描く。
private struct TVGuideCell: View {
    let item: GuideProgramItem
    let title: AttributedString
    let height: Double
    let viewportTop: Double
    let viewportHeight: Double
    let textScale: Double

    var body: some View {
        let lines = GuideText.tvCellLines(height: height, textScale: textScale)
        let inset = GuideLayout.tvCellContentInset(
            viewportTop: viewportTop, viewportHeight: viewportHeight, cellHeight: height,
            headingHeight: GuideText.tvCellHeadingHeight(titleLines: lines.title, textScale: textScale)
        )
        VStack(alignment: .leading, spacing: 4) {
            if lines.title > 0 {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(genreColor)
                        .frame(width: 11, height: 11)
                        .padding(.top, 11)
                    Text(title)
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
        .padding(.vertical, GuideText.tvCellVerticalPadding)
        .frame(width: GuideLayout.tvColumnWidth, height: height, alignment: .topLeading)
        .offset(y: inset ?? 0)
        .opacity(inset == nil ? 0 : 1)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 「`H:mm` ✓ 予約済み 番組名」。予約の印は題の行に並べる (TV-Guide の画面案)
    static func title(for item: GuideProgramItem) -> AttributedString {
        let time = Wording.time(Date(timeIntervalSince1970: Double(item.startAt) / 1000), calendar: GuideLayout.calendar)
        var text = AttributedString("\(time) ")
        for badge in GuideText.cellBadges(reservation: item.reservation) {
            var run = AttributedString("\(mark(of: badge)) ")
            run.foregroundColor = color(of: badge)
            text.append(run)
        }
        text.append(AttributedString(item.name))
        return text
    }

    /// 録画中は絵のとおり赤い「●」だけにする (iPhone/iPad の「● 録画中」はそのまま)
    private static func mark(of badge: GuideCellBadge) -> String {
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

    private static func color(of badge: GuideCellBadge) -> Color {
        switch badge {
        case .reserved: Color.accentColor
        case .recording: Color.red
        case .conflict: Color.orange
        }
    }
}
