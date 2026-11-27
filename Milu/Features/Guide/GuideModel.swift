import Foundation
import Observation

/// 番組表のマス 1 つぶん (GuideService と GuideProgram をくっつけた表示用の型)。
struct GuideProgramItem: Identifiable, Equatable, Sendable {
    let id: Int64
    /// 局の id。検索の行から来た番組で、局名が一意に引けないときは `nil` (ライブで観るを出さない)
    let serviceID: Int64?
    let serviceName: String
    /// 局ロゴの相対 URL。無ければ局名の頭 1 字 (3.5)
    let logo: String?
    let remoteControlKey: Int?
    let name: String
    let description: String?
    let startAt: Int64
    let endAt: Int64
    /// ジャンルの大分類 (ARIB の lv1)。マスの色と点に使う
    let genre: Int?
    let reservation: ReservationInfo?

    init(service: GuideService, program: GuideProgram) {
        id = program.id
        serviceID = service.id
        serviceName = service.name
        logo = service.logo
        remoteControlKey = service.remoteControlKey
        name = program.name
        description = program.description
        startAt = program.startAt
        endAt = program.endAt
        genre = program.genre
        reservation = program.reservation
    }
}

/// 番組表のタブの状態 (3.5)。読み・予約・取り消し・「ライブで観る」の求めを受け持つ。
@MainActor
@Observable
final class GuideModel: ProgramSheetModel {
    private let app: AppModel
    private var subscriptions: [AppModel.Subscription] = []
    private var didLoadTypes = false
    private var loadGeneration = 0

    private(set) var guide: GuideResponse?
    /// 局のある種別だけ、地上波・BS・CS・ケーブル・スカパー の順 (3.5)
    private(set) var availableTypes: [ServiceType] = ServiceType.allCases
    private(set) var selectedType: ServiceType = .GR
    private(set) var selectedDay: Date
    private(set) var isLoading = false
    /// 一覧を取れなかった (3.5 の「繋がらない」)
    private(set) var didFail = false

    // MARK: tvOS の窓 (状態)。1 日ずつ読んで、1 つの表につなぐ

    /// 表の始まりの放送日。開いたときに決め、セッション中は動かさない (送りの座標がずれないように)
    private(set) var tvBase: Date?
    /// いま持っている放送日 (昇順・連続)
    private(set) var tvDays: [Date] = []
    private(set) var tvGuide: GuideResponse?
    private(set) var tvDidFail = false
    private var tvResponses: [Int64: GuideResponse] = [:]
    private var tvGeneration = 0
    /// 最後に表に採用したカーソルの放送日 (SSE の読み直しに使う)
    private var tvCenter: Date?
    private var tvLoading: TVLoading?
    private var tvRequestedType: ServiceType?
    private var tvIsScrollAnimating = false
    private var tvPendingWindow: TVWindow?
    private var isTVGuide = false

    private struct TVLoading {
        let center: Date
        let type: ServiceType
        let task: Task<Bool, Never>
        var explicit: Bool
    }

    private struct TVWindow {
        let center: Date
        let days: [Date]
        let responses: [Int64: GuideResponse]
        let guide: GuideResponse
    }

    init(app: AppModel, now: Date = Date()) {
        self.app = app
        selectedDay = GuideLayout.broadcastDay(for: now)
    }

    /// 番組表が開いている間だけ SSE を受ける (4.3)。閉じたら購読を外す。
    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            app.addEventListener { [weak self] event in
                self?.handle(event)
            },
            app.addReconnectListener { [weak self] in
                guard let self else { return }
                Task { await self.refresh() }
            },
        ]
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    private func handle(_ event: SSEEvent) {
        switch event.event {
        case "programs", "reservations", "recordings":
            Task { await refresh() }
        default:
            break
        }
    }

    /// 読み直し。tvOS は窓を、iOS は 1 日を読む
    func refresh(now: Date = Date()) async {
        if isTVGuide {
            while let loading = tvLoading, loading.explicit { _ = await loading.task.value }
            let center = tvPendingWindow?.center ?? tvLoading?.center ?? tvCenter ?? selectedDay
            await tvReload(center: center, now: now, force: true)
        } else {
            await reload()
        }
    }

    /// 日付のメニューに並べる日。今日から 8 日ぶんで、until より先は並べない (3.5)
    var menuDays: [Date] {
        GuideLayout.menuDays(now: Date(), until: isTVGuide ? tvGuide?.until : guide?.until)
    }

    /// 表の先頭 (UNIX ミリ秒)。セッション中は動かさない
    var tvFrom: Int64 { GuideLayout.broadcastRange(for: tvBase ?? selectedDay).from }
    /// 表の末尾。持っている最後の日の翌 4:00
    var tvTo: Int64 { tvDays.last.map { GuideLayout.broadcastRange(for: $0).to } ?? tvFrom }

    /// いま開いている範囲の番組 (シートの中身の最新)
    func program(id: Int64) -> GuideProgramItem? {
        let source = isTVGuide ? tvGuide : guide
        return source?.services.lazy.flatMap { service in
            service.programs.map { GuideProgramItem(service: service, program: $0) }
        }.first { $0.id == id }
    }

    func selectType(_ type: ServiceType) {
        guard type != selectedType else { return }
        selectedType = type
        Task { await reload() }
    }

    func selectDay(_ day: Date) {
        guard !GuideLayout.calendar.isDate(day, inSameDayAs: selectedDay) else { return }
        selectedDay = day
        Task { await reload() }
    }

    /// 開いている範囲を読み直す (4.3 の SSE の入口もこれ)。
    func reload() async {
        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoading = true
        didFail = false
        do {
            try await loadTypesIfNeeded()
            let range = GuideLayout.broadcastRange(for: selectedDay)
            let path = "api/programs?type=\(selectedType.rawValue)&from=\(range.from)&to=\(range.to)"
            let data = try await app.get(path)
            let decoded = try JSONDecoder().decode(GuideResponse.self, from: data)
            guard generation == loadGeneration else { return }
            guide = decoded
        } catch {
            guard generation == loadGeneration else { return }
            didFail = true
        }
        isLoading = false
    }

    private func loadTypesIfNeeded() async throws {
        guard !didLoadTypes else { return }
        let data = try await app.get("api/services")
        let services = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data)
        let types = ServiceType.allCases.filter { type in
            services.contains { $0.type == type }
        }
        guard !didLoadTypes else { return }
        availableTypes = types.isEmpty ? ServiceType.allCases : types
        didLoadTypes = true
        if !availableTypes.contains(selectedType), let first = availableTypes.first {
            selectedType = first
        }
    }

    // MARK: tvOS の窓 (読み)

    /// tvOS の番組表を開く。開いた日〜翌日を読む (前の日は読まない)
    func tvStart(now: Date = Date()) async {
        await tvReload(center: tvCenter ?? GuideLayout.broadcastDay(for: now), now: now)
    }

    /// 種別は読みが採用されたときに確定する。
    @discardableResult
    func tvSelectType(_ type: ServiceType) -> Bool {
        guard type != (tvRequestedType ?? selectedType) else { return false }
        invalidateTVRead()
        tvRequestedType = type == selectedType ? nil : type
        return tvRequestedType != nil
    }

    /// カーソルの放送日の前後 1 日を読む。明示選択は同じ先読みを待ち、採用されたときに成功を返す。
    @discardableResult
    func tvReload(center: Date, now: Date = Date(), force: Bool = false, explicit: Bool = false) async -> Bool {
        let type = tvRequestedType ?? selectedType
        if let loading = tvLoading {
            if loading.center == center, loading.type == type, !force {
                if explicit { tvLoading?.explicit = true }
                return await loading.task.value
            }
            if loading.explicit, !explicit { return false }
        }
        let explicit = explicit || tvRequestedType != nil
        if !force, let pending = tvPendingWindow, pending.center == center, pending.guide.type == type {
            if explicit { adoptTVWindow(pending) }
            return pending.days.contains(center)
        }

        invalidateTVRead()
        let generation = tvGeneration
        isTVGuide = true
        if tvBase == nil { tvBase = center }
        let task = Task {
            defer {
                if generation == tvGeneration {
                    tvLoading = nil
                    tvRequestedType = nil
                }
            }
            do {
                try await loadTypesIfNeeded()
            } catch {
                if generation == tvGeneration, tvGuide == nil { tvDidFail = true }
                return false
            }
            guard generation == tvGeneration else { return false }
            let type = tvRequestedType ?? selectedType
            let window = await readTVWindow(
                center: center, type: type, now: now, force: force, generation: generation
            )
            guard generation == tvGeneration else { return false }
            guard let window else {
                if tvGuide == nil { tvDidFail = true }
                return false
            }
            if tvIsScrollAnimating, tvLoading?.explicit != true {
                tvPendingWindow = window
            } else {
                adoptTVWindow(window)
            }
            return window.days.contains(center) || force
        }
        tvLoading = TVLoading(center: center, type: type, task: task, explicit: explicit)
        return await task.value
    }

    /// 送りの連鎖が終わるまで、描画中のマスと時刻目盛りの窓を保持する。
    func tvSetScrollAnimating(_ animating: Bool) {
        tvIsScrollAnimating = animating
        if !animating, let pending = tvPendingWindow { adoptTVWindow(pending) }
    }

    enum TVEdgeResult: Equatable {
        case moved, exhausted, waiting
    }

    /// 窓の外を隣の日から順に調べ、同じ局の次の番組を見つけるまで表示中の窓を保つ。
    func tvExtend(
        from cursor: GuideCursor, direction: Int, now: Date = Date(),
        onMove: (GuideCursor) -> Void = { _ in }
    ) async -> TVEdgeResult {
        guard direction == -1 || direction == 1, tvLoading?.explicit != true, tvRequestedType == nil,
              let guide = tvGuide,
              let (_, current) = GuideCursorMotion.program(cursor, in: guide.services),
              let base = tvBase, let edge = direction < 0 ? tvDays.first : tvDays.last
        else { return .waiting }
        let serviceID = guide.services[cursor.column].id
        let last = GuideLayout.menuDays(now: now, until: guide.until).last ?? base
        invalidateTVRead()
        let generation = tvGeneration
        var day = edge
        while let next = GuideLayout.calendar.date(byAdding: .day, value: direction, to: day),
              base <= next, next <= last {
            day = next
            guard let response = await readTVDay(day, type: guide.type, generation: generation) else { return .waiting }
            if let until = response.until, key(day) >= until {
                if direction > 0 { return .exhausted }
                continue
            }

            let programs = response.services.first { $0.id == serviceID }?.programs ?? []
            let candidates = programs.filter {
                $0.id != current.id && (direction < 0 ? $0.startAt < current.startAt : $0.startAt > current.startAt)
            }
            let program = direction < 0
                ? candidates.max { $0.startAt < $1.startAt }
                : candidates.min { $0.startAt < $1.startAt }
            guard let program else { continue }

            let window = await readTVWindow(
                center: day, type: guide.type, now: now, force: false, generation: generation, seed: response
            )
            guard generation == tvGeneration, !Task.isCancelled, let window,
                  let column = window.guide.services.firstIndex(where: { $0.id == serviceID }),
                  window.guide.services[column].programs.contains(where: { $0.id == program.id })
            else { return .waiting }

            // 番組の空きを越えるときは、窓と送り先を同じ更新で切り替える。
            adoptTVWindow(window)
            onMove(GuideCursor(column: column, programID: program.id, anchor: max(program.startAt, key(day))))
            return .moved
        }
        return .exhausted
    }

    private func invalidateTVRead() {
        tvGeneration += 1
        tvLoading?.task.cancel()
        tvLoading = nil
        tvPendingWindow = nil
    }

    private func readTVDay(_ day: Date, type: ServiceType, generation: Int) async -> GuideResponse? {
        guard generation == tvGeneration, !Task.isCancelled else { return nil }
        let range = GuideLayout.broadcastRange(for: day)
        let path = "api/programs?type=\(type.rawValue)&from=\(range.from)&to=\(range.to)"
        guard let data = try? await app.get(path), generation == tvGeneration, !Task.isCancelled else { return nil }
        return try? JSONDecoder().decode(GuideResponse.self, from: data)
    }

    private func readTVWindow(
        center: Date, type: ServiceType, now: Date, force: Bool, generation: Int,
        seed: GuideResponse? = nil, refreshedUntil: Int64? = nil
    ) async -> TVWindow? {
        guard let base = tvBase else { return nil }
        let previousUntil = tvGuide?.type == type ? tvGuide?.until : nil
        let knownUntil = refreshedUntil ?? previousUntil
        let last = GuideLayout.menuDays(now: now, until: knownUntil).last ?? base
        let days = GuideLayout.tvWindowDays(center: center, first: base, last: last)
        guard !days.isEmpty else { return nil }

        // 取得結果は採用までローカルに置く。失敗・追い越しで表示窓の外にキャッシュを残さない。
        var responses: [Int64: GuideResponse] = [:]
        var fresh: [GuideResponse] = []
        for day in days {
            let start = key(day)
            if let seed, seed.from == start {
                responses[start] = seed
                fresh.append(seed)
            } else if !force, tvGuide?.type == type, let cached = tvResponses[start] {
                responses[start] = cached
            } else if let response = await readTVDay(day, type: type, generation: generation) {
                responses[start] = response
                fresh.append(response)
            } else if force, tvGuide?.type == type {
                responses[start] = tvResponses[start]
            }
            guard generation == tvGeneration, !Task.isCancelled else { return nil }
        }

        let until = fresh.isEmpty ? knownUntil : fresh.compactMap(\.until).max()
        let eligible = days.filter { day in until.map { key(day) < $0 } ?? true }
        let effectiveCenter: Date
        if let until, key(center) >= until {
            guard let last = GuideLayout.menuDays(now: now, until: until).last, last >= base else {
                let guide = GuideResponse(type: type, from: tvFrom, to: tvFrom, until: until, services: [])
                return TVWindow(center: base, days: [], responses: [:], guide: guide)
            }
            guard force else { return nil }
            if !eligible.contains(last), refreshedUntil == nil {
                return await readTVWindow(
                    center: last, type: type, now: now, force: true, generation: generation, refreshedUntil: until
                )
            }
            effectiveCenter = last
        } else {
            effectiveCenter = center
        }
        guard let index = eligible.firstIndex(of: effectiveCenter), responses[key(effectiveCenter)] != nil else { return nil }
        let before = eligible[..<index].reversed().prefix { responses[key($0)] != nil }
        let after = eligible[index...].prefix { responses[key($0)] != nil }
        let loaded = Array(before.reversed()) + after
        let adopted = responses.filter { start, _ in loaded.contains { key($0) == start } }
        guard let merged = Self.merge(Array(adopted.values)) else { return nil }
        let guide = GuideResponse(type: type, from: merged.from, to: merged.to, until: until, services: merged.services)
        return TVWindow(center: effectiveCenter, days: loaded, responses: adopted, guide: guide)
    }

    private func adoptTVWindow(_ window: TVWindow) {
        tvPendingWindow = nil
        tvDays = window.days
        tvGuide = window.guide
        tvResponses = window.responses
        tvCenter = window.center
        selectedType = window.guide.type
        tvDidFail = false
    }

    private func key(_ day: Date) -> Int64 {
        GuideLayout.broadcastRange(for: day).from
    }

    /// 放送日の読みを 1 つの表につなぐ。局は id で寄せ、番組は id で重複を落として始まり順に並べる
    nonisolated static func merge(_ responses: [GuideResponse]) -> GuideResponse? {
        let responses = responses.sorted { $0.from < $1.from }
        guard let first = responses.first, let last = responses.last else { return nil }
        var services: [Int64: GuideService] = [:]
        var order: [Int64] = []
        var programs: [Int64: [Int64: GuideProgram]] = [:]
        func hasMark(_ program: GuideProgram) -> Bool {
            if case .some = program.reservation { return true }
            return program.recordingId != nil
        }
        for response in responses {
            for service in response.services {
                if services.index(forKey: service.id) == nil {
                    services[service.id] = service
                    order.append(service.id)
                    programs[service.id] = [:]
                }
                for program in service.programs {
                    // 4:00 をまたぐ番組は両日に入る。予約・録画の印が載っている方を残す
                    if let existing = programs[service.id]?[program.id], hasMark(existing), !hasMark(program) {
                        continue
                    }
                    programs[service.id]?[program.id] = program
                }
            }
        }
        let merged = order.compactMap { id -> GuideService? in
            guard var service = services[id] else { return nil }
            service.programs = (programs[id] ?? [:]).values.sorted {
                $0.startAt == $1.startAt ? $0.id < $1.id : $0.startAt < $1.startAt
            }
            return service
        }
        return GuideResponse(
            type: first.type,
            from: first.from,
            to: last.to,
            until: responses.compactMap(\.until).max(),
            services: merged
        )
    }

    /// 番組の中身。終わった番組は 404 なので、そのときはマスの持つ分だけを出す (3.5)
    func detail(_ item: GuideProgramItem) async -> ProgramDetail? {
        do {
            let data = try await app.get("api/programs/\(item.id)")
            return try JSONDecoder().decode(ProgramDetail.self, from: data)
        } catch {
            return nil
        }
    }

    /// 録画を予約。失敗したら alert に出す文を返す。200 だが録らない状態ならその理由を返す (3.5)
    @discardableResult
    func reserve(_ item: GuideProgramItem) async -> String? {
        do {
            let data = try await app.post("api/programs/\(item.id)/record")
            guard let response = try? JSONDecoder().decode(RecordResponse.self, from: data) else {
                await refresh()
                return nil
            }
            if response.reserved {
                await refresh()
                return nil
            }
            return response.reason ?? String(localized: "録画できません")
        } catch {
            return Self.failureMessage(error)
        }
    }

    /// 予約を取り消す (録画中ならそこまでの録画は残る)。失敗したら alert に出す文を返す。
    @discardableResult
    func cancel(_ item: GuideProgramItem) async -> String? {
        do {
            _ = try await app.delete("api/programs/\(item.id)/record")
            await refresh()
            return nil
        } catch {
            return Self.failureMessage(error)
        }
    }

    /// 「ライブで観る」。ライブのタブへ移ってこの局を映す求めを置く (3.5)。映す所は本線の PR 3。
    func watchLive(_ item: GuideProgramItem) {
        guard let serviceID = item.serviceID else { return }
        app.requestLiveWatch(serviceID: serviceID)
    }

    /// 予約・取り消しの失敗を画面に出す文。検索の番組の詳細からも同じ文を使う (D31)
    nonisolated static func failureMessage(_ error: Error) -> String {
        guard let error = error as? AppModel.APIError else { return String(localized: "denpa と通信できません") }
        switch error {
        case .notConnected:
            return String(localized: "denpa に接続されていません")
        case .needsPairing:
            return String(localized: "認証が必要です")
        case .decoding:
            return String(localized: "denpa からの応答を読み取れませんでした")
        case .http(_, let message):
            return message ?? String(localized: "denpa と通信できません")
        case .network:
            return String(localized: "denpa に接続できません")
        }
    }
}
