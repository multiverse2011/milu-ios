import SwiftUI

/// 番組表の画面 (3.5・iPhone-Guide・iPad-Guide)。局の行と時刻の列は貼り付く。
struct GuideView: View {
    let model: GuideModel
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// マスの印の字の大きさ。マスごとに持たず、ここで 1 回だけ決める
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 11

    @State private var sheetItem: GuideProgramItem?

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private var timeWidth: CGFloat {
        CGFloat(GuideLayout.timeColumnWidth(horizontalSizeClassRegular: isRegular))
    }

    private var columnWidth: CGFloat {
        CGFloat(GuideLayout.columnWidth(horizontalSizeClassRegular: isRegular))
    }

    /// 局の行の高さ (画面案の 30 + 下の線)
    private let headerHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            if model.didFail, model.guide == nil {
                OfflineView(host: app.server?.displayName ?? "") {
                    Task { await model.reload() }
                }
            } else if let guide = model.guide {
                grid(guide)
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            await model.reload()
        }
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .sheet(item: $sheetItem) { item in
            ProgramSheetView(item: item, model: model, horizontalSizeClassRegular: isRegular)
        }
    }

    // MARK: 上の段

    /// 題・日付のメニュー・種別の Picker。iPad は題を出さず、種別と日付を 1 段に並べる (iPad-Guide)
    private func topBar(types: [ServiceType]) -> some View {
        let picker = typePicker(types)
        return Group {
            if isRegular {
                HStack(spacing: 12) {
                    picker
                        .frame(width: 400, height: 44)
                        .scaledFont(17)
                        .controlSize(.large)
                    Spacer(minLength: 0)
                    dateMenu
                        .scaledFont(17)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(height: 84, alignment: .top)
            } else {
                VStack(spacing: 6) {
                    // 大きい字では題と日付が重なるので、左右に分ける
                    if dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 12) {
                            Text("番組表")
                                .scaledFont(17, weight: .semibold)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            dateMenu
                                .scaledFont(17)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 50)
                    } else {
                        HStack {
                            Spacer(minLength: 0)
                            dateMenu
                        }
                        .overlay {
                            Text("番組表")
                                .scaledFont(17, weight: .semibold)
                        }
                        .frame(height: 50)
                        .padding(.trailing, 8)
                    }
                    picker.padding(.horizontal, 20)
                }
                .padding(.bottom, 8)
            }
        }
    }

    /// 日付のメニュー。今日から 8 日ぶん (3.5・iPhone-GuideMenu)
    private var dateMenu: some View {
        Menu {
            Picker(
                "日付",
                selection: Binding(get: { model.selectedDay }, set: { model.selectDay($0) })
            ) {
                ForEach(model.menuDays, id: \.self) { day in
                    Text(GuideLayout.menuLabel(for: day, today: Date())).tag(day)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(GuideLayout.menuLabel(for: model.selectedDay, today: Date()))
                    .scaledFont(isRegular ? 17 : 15, weight: .semibold)
                Image(systemName: "chevron.down")
                    .scaledFont(11, weight: .bold)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .glassEffect()
        }
    }

    /// 種別の Picker (局のある種別だけ。ライブと同じ決まり)
    private func typePicker(_ types: [ServiceType]) -> some View {
        Picker(
            "種別",
            selection: Binding(get: { model.selectedType }, set: { model.selectType($0) })
        ) {
            ForEach(types, id: \.self) { type in
                Text(GuideText.typeLabel(type)).tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: 格子

    private func grid(_ guide: GuideResponse) -> some View {
        let range = GuideLayout.broadcastRange(for: model.selectedDay)
        return VStack(spacing: 0) {
            topBar(types: model.availableTypes)
            GuideGrid(
                guide: guide,
                selectedDay: model.selectedDay,
                rangeStart: Double(range.from),
                rangeEnd: Double(range.to),
                timeWidth: timeWidth,
                columnWidth: columnWidth,
                isRegular: isRegular,
                badgeSize: badgeSize,
                sheetItem: $sheetItem
            )
        }
    }
}

/// 番組表の格子。送りの位置はこの中の状態にして、上の段 (題・日付・種別の Picker) が
/// 送るたびに作り直されないようにする
private struct GuideGrid: View {
    let guide: GuideResponse
    let selectedDay: Date
    let rangeStart: Double
    let rangeEnd: Double
    let timeWidth: CGFloat
    let columnWidth: CGFloat
    let isRegular: Bool
    let badgeSize: CGFloat
    @Binding var sheetItem: GuideProgramItem?

    @State private var didInitialScroll = false
    /// 格子の送り位置 (貼り付く局の行と時刻の列を、これだけ逆へずらす)
    @State private var scrollX: CGFloat = 0
    @State private var scrollY: CGFloat = 0

    /// 局の行の高さ (画面案の 30 + 下の線)
    private let headerHeight: CGFloat = 34

    var body: some View {
        let totalHeight = GuideLayout.height(rangeStart: rangeStart, rangeEnd: rangeEnd)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        columns(
                            guide,
                            rangeStart: rangeStart,
                            rangeEnd: rangeEnd,
                            totalHeight: totalHeight,
                            viewport: viewport.size
                        )
                        .overlay(alignment: .topLeading) {
                            nowOverlay(now: now, rangeStart: rangeStart, rangeEnd: rangeEnd)
                        }
                        .padding(.leading, timeWidth)
                        .padding(.top, headerHeight)
                        .padding(.bottom, 8)
                        .overlay(alignment: .topLeading) {
                            // 開いたときの送り位置の目印 (いまの線が上から 1/4)。
                            // offset は layout の位置を変えないので、高さで置く
                            VStack(spacing: 0) {
                                Color.clear.frame(width: 1, height: headerHeight + nowOffset(now: now, rangeStart: rangeStart, rangeEnd: rangeEnd))
                                Color.clear.frame(width: 1, height: 1).id("guide-now")
                                Spacer(minLength: 0)
                            }
                            .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("guide-top")
                                .allowsHitTesting(false)
                        }
                    }
                    .onScrollGeometryChange(for: CGPoint.self) { geometry in
                        geometry.contentOffset
                    } action: { _, offset in
                        scrollX = offset.x
                        scrollY = offset.y
                    }
                    .overlay(alignment: .topLeading) {
                        channelHeader(guide)
                            .offset(x: -scrollX)
                    }
                    .overlay(alignment: .topLeading) {
                        timeColumn(rangeStart: rangeStart, now: now, viewportHeight: viewport.size.height)
                    }
                    .onAppear {
                        scrollIfNeeded(proxy: proxy, rangeStart: rangeStart, rangeEnd: rangeEnd)
                    }
                    .onChange(of: selectedDay) { _, _ in
                        scrollIfNeeded(proxy: proxy, rangeStart: rangeStart, rangeEnd: rangeEnd, force: true)
                    }
                }
            }
        }
    }

    /// 見えている所 (と前後半画面) の列だけを作る。CS の 54 局でも一度に全部は作らない
    private func columns(
        _ guide: GuideResponse,
        rangeStart: Double,
        rangeEnd: Double,
        totalHeight: Double,
        viewport: CGSize
    ) -> some View {
        let columns = visibleColumns(guide.services.count, viewport: viewport)
        let rows = visibleRows(viewport: viewport)
        return HStack(alignment: .top, spacing: GuideLayout.columnGap) {
            ForEach(guide.services.indices, id: \.self) { index in
                if columns.contains(index) {
                    channelColumn(
                        guide.services[index],
                        rangeStart: rangeStart,
                        rangeEnd: rangeEnd,
                        totalHeight: totalHeight,
                        rows: rows
                    )
                } else {
                    // 見えていない列は場所だけ取る
                    Color.clear
                        .frame(width: columnWidth, height: totalHeight)
                }
            }
        }
    }

    private func visibleColumns(_ count: Int, viewport: CGSize) -> ClosedRange<Int> {
        guard count > 0, viewport.width > 0 else { return 0...(max(count - 1, 0)) }
        let step = columnWidth + GuideLayout.columnGap
        let margin = viewport.width / 2
        let first = max(0, Int(((scrollX - margin - timeWidth) / step).rounded(.down)))
        let last = min(count - 1, Int(((scrollX + viewport.width + margin - timeWidth) / step).rounded(.down)))
        return first...max(first, last)
    }

    /// マスの上端 (`GuideLayout.frame` の `top`) で見る、作る範囲。前後半画面ぶんの余白を付ける
    private func visibleRows(viewport: CGSize) -> ClosedRange<Double> {
        guard viewport.height > 0 else { return -Double.infinity...Double.infinity }
        let margin = viewport.height / 2
        return (scrollY - headerHeight - margin)...(scrollY - headerHeight + viewport.height + margin)
    }

    private func nowOffset(now: Date, rangeStart: Double, rangeEnd: Double) -> CGFloat {
        let today = GuideLayout.calendar.isDate(selectedDay, inSameDayAs: GuideLayout.broadcastDay(for: now))
        guard today,
              let y = GuideLayout.nowOffset(
                  now: now.timeIntervalSince1970 * 1000,
                  rangeStart: rangeStart,
                  rangeEnd: rangeEnd
              )
        else { return 0 }
        return CGFloat(y)
    }

    /// 開いたときの送り位置 (3.5)。今日ならいまの線が上から 1/4、それ以外は上から。
    private func scrollIfNeeded(
        proxy: ScrollViewProxy,
        rangeStart: Double,
        rangeEnd: Double,
        force: Bool = false
    ) {
        guard force || !didInitialScroll else { return }
        didInitialScroll = true
        let today = GuideLayout.calendar.isDate(selectedDay, inSameDayAs: GuideLayout.broadcastDay(for: Date()))
        if today, nowOffset(now: Date(), rangeStart: rangeStart, rangeEnd: rangeEnd) > 0 {
            proxy.scrollTo("guide-now", anchor: UnitPoint(x: 0, y: 0.25))
        } else {
            proxy.scrollTo("guide-top", anchor: .topLeading)
        }
    }

    /// 局の列。マスは GuideLayout の計算どおり置く
    private func channelColumn(
        _ service: GuideService,
        rangeStart: Double,
        rangeEnd: Double,
        totalHeight: Double,
        rows: ClosedRange<Double>
    ) -> some View {
        let cells: [(item: GuideProgramItem, top: Double, height: Double)] = service.programs.compactMap { program -> (item: GuideProgramItem, top: Double, height: Double)? in
            guard let frame = GuideLayout.frame(
                start: Double(program.startAt),
                end: Double(program.endAt),
                rangeStart: rangeStart,
                rangeEnd: rangeEnd
            ),
                frame.top <= rows.upperBound,
                frame.top + frame.height >= rows.lowerBound
            else { return nil }
            return (item: GuideProgramItem(service: service, program: program), top: frame.top, height: frame.height)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(cells, id: \.item.id) { cell in
                let cellHeight = max(cell.height - 2, 1)
                ProgramCellView(item: cell.item, height: cellHeight, badgeSize: badgeSize)
                    .frame(width: columnWidth, height: cellHeight)
                    .offset(y: cell.top + 1)
                    .onTapGesture {
                        sheetItem = cell.item
                    }
            }
        }
        .frame(width: columnWidth, height: totalHeight, alignment: .topLeading)
    }

    /// 貼り付く局の行 (ロゴ・リモコン番号・局名)
    private func channelHeader(_ guide: GuideResponse) -> some View {
        HStack(spacing: GuideLayout.columnGap) {
            ForEach(guide.services, id: \.id) { service in
                HStack(spacing: 6) {
                    ChannelLogoView(path: service.logo, serviceName: service.name)
                    if let number = service.remoteControlKey {
                        Text("\(number)")
                            .scaledFont(isRegular ? 12 : 11.5)
                            .foregroundStyle(.secondary)
                    }
                    Text(service.name)
                        .font(DenpaFont.font(size: isRegular ? 13.5 : 13))
                        .bold()
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(width: columnWidth, height: 30, alignment: .leading)
            }
        }
        .padding(.leading, timeWidth)
        .frame(height: headerHeight, alignment: .bottom)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
    }

    /// 貼り付く時刻の列 (時の数字といまの線の左の数字)
    private func timeColumn(rangeStart: Double, now: Date, viewportHeight: CGFloat) -> some View {
        let nowY = nowOffset(now: now, rangeStart: rangeStart, rangeEnd: rangeStart + 86_400_000)
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                ForEach(0..<24, id: \.self) { hour in
                    let time = rangeStart + Double(hour) * 3_600_000
                    let hourY = headerHeight + GuideLayout.offset(of: time, from: rangeStart) + 4
                    // いまの線の時刻 (赤) と重なるときは、時の数字を出さない
                    let overlapsNow = nowY > 0 && abs(hourY - (headerHeight + nowY - 8)) < 30
                    // 画面の外の時は作らない
                    let onScreen = viewportHeight <= 0 || (hourY - scrollY > -60 && hourY - scrollY < viewportHeight + 60)
                    if !overlapsNow, onScreen {
                        Text("\(GuideLayout.calendar.component(.hour, from: Date(timeIntervalSince1970: time / 1000)))")
                            .scaledFont(isRegular ? 13 : 12, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: timeWidth)
                            .offset(y: hourY)
                    }
                }
                if nowY > 0 {
                    Text(GuideLayout.nowLineLabel(now: now, horizontalSizeClassRegular: isRegular))
                        .scaledFont(isRegular ? 12 : 11.5, weight: .bold)
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                        // 列の幅は決まっている。大きい字でも折り返さない
                        .minimumScaleFactor(0.7)
                        .frame(width: timeWidth)
                        .offset(y: headerHeight + nowY - 8)
                }
            }
            .offset(y: -scrollY)
        }
        .frame(width: timeWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .clipped()
        .overlay(alignment: .top) {
            // 局の行のぶんは時刻を出さない (局の行はこの列の上に重ねる)
            Rectangle()
                .fill(Color(uiColor: .systemBackground))
                .frame(height: headerHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(height: 0.5)
                }
        }
    }

    /// いまの線・点と、過ぎた所の黒 (今日の表だけ。3.5)
    @ViewBuilder
    private func nowOverlay(now: Date, rangeStart: Double, rangeEnd: Double) -> some View {
        let nowY = nowOffset(now: now, rangeStart: rangeStart, rangeEnd: rangeEnd)
        if nowY > 0 {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(height: nowY)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 1)
                    .offset(y: nowY)
                    .allowsHitTesting(false)
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: -2.5, y: nowY - 2.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// 番組表のマス (角 3。ジャンルの点・時刻・番組名・説明・予約の印。3.5・milu.css の .cell)
struct ProgramCellView: View {
    let item: GuideProgramItem
    /// マスの高さ (入る行の数を決める)
    let height: Double
    /// 印の字の大きさ (画面が 1 回決めて渡す)
    let badgeSize: CGFloat

    private var badges: [GuideCellBadge] {
        GuideText.cellBadges(reservation: item.reservation)
    }

    var body: some View {
        let lines = GuideText.cellLines(height: height, hasBadge: !badges.isEmpty)
        VStack(alignment: .leading, spacing: 2) {
            if lines.title > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Circle()
                        .fill(genreColor)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0.height - 1 }
                    Text("\(startTime) \(item.reservation?.state == .scheduled ? "✓ " : "")\(item.name)")
                        .font(DenpaFont.font(size: 12.5))
                        .lineSpacing(1)
                        .lineLimit(lines.title)
                        .truncationMode(.tail)
                }
                if lines.showsBadge {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge.text)
                            .font(.system(size: badgeSize, weight: .bold))
                            .foregroundStyle(color(of: badge))
                    }
                }
                if lines.description > 0, let description = item.description, !description.isEmpty {
                    Text(description)
                        .font(DenpaFont.font(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .lineLimit(lines.description)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 3))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .foregroundStyle(.primary)
        .contentShape(RoundedRectangle(cornerRadius: 3))
    }

    private var startTime: String {
        Wording.time(Date(timeIntervalSince1970: Double(item.startAt) / 1000), calendar: GuideLayout.calendar)
    }

    private var genreColor: Color {
        guard let rgba = GenreColor.color(item.genre) else { return Color.secondary }
        return Color(.sRGB, red: Double(rgba.r) / 255, green: Double(rgba.g) / 255, blue: Double(rgba.b) / 255)
    }

    private var backgroundColor: Color {
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
