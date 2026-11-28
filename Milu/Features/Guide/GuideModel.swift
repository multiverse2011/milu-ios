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

    // MARK: tvOS の全日表示

    /// 開いたときの放送日。日を追加してもセッション中の縦座標は変えない。
    private(set) var tvBase: Date?
    private(set) var tvGuide: GuideResponse?
    private(set) var tvDidFail = false
    /// 採用済みの種別の日別応答。起点の日の応答が全体の until を決める。
    private var tvResponses: [Date: GuideResponse] = [:]
    /// 現在の世代の応答だけを採用する。
    private var tvGeneration = 0
    /// 一括取得は最大 1 つ。新しい世代を始めると前の取得を取り消す。
    private var tvLoadTask: Task<Void, Never>?
    /// 新しい種別は起点の日を読めるまで選択表示に反映しない。
    private var tvRequestedType: ServiceType?
    /// 現在の世代の日別取得状況。追加の再試行は同時に 1 日だけ。
    private var tvDayLoads: [Date: TVDayLoad] = [:]
    private var isTVGuide = false

    private enum TVDayLoad {
        case loading, retrying, retried
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

    /// 読み直し。tvOS は全日を、iOS は 1 日を読む。
    func refresh(now: Date = Date()) async {
        if isTVGuide {
            let today = GuideLayout.broadcastDay(for: now)
            await loadTVGuide(base: tvRequestedType == nil ? tvBase ?? today : today)
        } else {
            await reload()
        }
    }

    /// 日付のメニューに並べる日。今日から 8 日ぶんで、until より先は並べない (3.5)
    var menuDays: [Date] {
        menuDays(now: Date())
    }

    func menuDays(now: Date) -> [Date] {
        if isTVGuide { return tvDays }
        return GuideLayout.menuDays(now: now, until: guide?.until)
    }

    /// 起点の日の応答から決めた全日。取得中・失敗の日も同じ座標とチップを持つ。
    var tvDays: [Date] {
        guard let tvBase, let today = tvResponses[tvBase] else { return [] }
        return GuideLayout.menuDays(now: Date(timeIntervalSince1970: Double(tvFrom) / 1000), until: today.until)
    }

    var tvFrom: Int64 { GuideLayout.broadcastRange(for: tvBase ?? selectedDay).from }
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

    // MARK: tvOS の全日取得

    func tvStart(now: Date = Date()) async {
        isTVGuide = true
        await loadTVGuide(base: GuideLayout.broadcastDay(for: now))
    }

    func tvSelectType(_ type: ServiceType, now: Date = Date()) async {
        guard type != (tvRequestedType ?? selectedType) else { return }
        tvRequestedType = type
        await loadTVGuide(base: GuideLayout.broadcastDay(for: now))
    }

    private func loadTVGuide(base: Date) async {
        tvGeneration += 1
        let generation = tvGeneration
        tvLoadTask?.cancel()
        tvDayLoads = Dictionary(uniqueKeysWithValues: tvDays.map { ($0, .loading) })
        let task = Task {
            defer {
                if generation == tvGeneration {
                    tvLoadTask = nil
                    tvRequestedType = nil
                    tvDayLoads = tvDayLoads.filter { $0.value != .loading }
                }
            }
            do {
                try await loadTypesIfNeeded()
            } catch {
                if generation == tvGeneration, !Task.isCancelled, tvGuide == nil { tvDidFail = true }
                return
            }
            guard generation == tvGeneration, !Task.isCancelled else { return }
            let type = tvRequestedType ?? selectedType
            let today = await Self.readTVDay(base, type: type, app: app)
            guard generation == tvGeneration, !Task.isCancelled else { return }

            let sameGuide = base == tvBase && type == selectedType
            if let today {
                if !sameGuide { tvResponses.removeAll() }
                tvBase = base
                tvResponses[base] = today
                let days = Set(tvDays)
                tvResponses = tvResponses.filter { $0.key == base || days.contains($0.key) }
                selectedType = type
                tvDidFail = false
                publishTVGuide()
            } else if !sameGuide || tvResponses[base] == nil {
                if tvGuide == nil { tvDidFail = true }
                return
            }

            tvRequestedType = nil
            await loadTVRemainingDays(tvDays.filter { $0 != base }, type: type, generation: generation)
        }
        tvLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadTVRemainingDays(_ days: [Date], type: ServiceType, generation: Int) async {
        tvDayLoads = Dictionary(uniqueKeysWithValues: days.map { ($0, .loading) })
        let app = self.app
        var remaining = days.makeIterator()
        await withTaskGroup(of: (Date, GuideResponse?).self) { group in
            for _ in 0..<3 {
                guard let day = remaining.next() else { break }
                group.addTask { (day, await Self.readTVDay(day, type: type, app: app)) }
            }
            for await (day, response) in group {
                guard generation == tvGeneration, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                tvDayLoads[day] = nil
                if tvResponses[day] != response {
                    tvResponses[day] = response
                    publishTVGuide()
                }
                if let day = remaining.next() {
                    group.addTask { (day, await Self.readTVDay(day, type: type, app: app)) }
                }
            }
        }
    }

    /// 次の番組までに未取得の日があれば、下送りはそこで待つ。再試行も失敗した日は空きとして進める。
    func tvBlockingDay(after time: Int64, before next: Int64?) -> Date? {
        let start = GuideLayout.broadcastDay(for: Date(timeIntervalSince1970: Double(time) / 1000))
        let end = next.map { GuideLayout.broadcastDay(for: Date(timeIntervalSince1970: Double($0) / 1000)) }
        return tvDays.first { day in
            day >= start && day <= (end ?? day) && tvResponses[day] == nil && tvDayLoads[day] != .retried
        }
    }

    /// 通常取得を終えた空の日だけを、更新世代につき 1 回読み直す。
    func tvRetry(day: Date) async {
        guard tvRequestedType == nil, tvDays.contains(day), tvResponses[day] == nil, tvDayLoads[day] == nil,
              !tvDayLoads.values.contains(.retrying)
        else { return }
        tvDayLoads[day] = .retrying
        let generation = tvGeneration
        let response = await Self.readTVDay(day, type: selectedType, app: app)
        guard generation == tvGeneration else { return }
        tvDayLoads[day] = .retried
        if let response {
            tvResponses[day] = response
            publishTVGuide()
        }
    }

    private nonisolated static func readTVDay(_ day: Date, type: ServiceType, app: AppModel) async -> GuideResponse? {
        guard !Task.isCancelled else { return nil }
        let range = GuideLayout.broadcastRange(for: day)
        let path = "api/programs?type=\(type.rawValue)&from=\(range.from)&to=\(range.to)"
        guard let data = try? await app.get(path), !Task.isCancelled,
              let response = try? JSONDecoder().decode(GuideResponse.self, from: data), response.type == type
        else { return nil }
        return response
    }

    private func publishTVGuide() {
        let responses = tvDays.compactMap { tvResponses[$0] }
        tvGuide = GuideResponse(
            type: selectedType, from: tvFrom, to: tvTo, until: tvBase.flatMap { tvResponses[$0]?.until },
            services: Self.merge(responses)?.services ?? []
        )
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
