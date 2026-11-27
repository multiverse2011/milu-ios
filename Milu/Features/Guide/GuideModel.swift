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
    /// 読み込み中の (中心の日, 種別)。同じ読みを重ねない
    private var tvLoading: [TVLoading] = []
    private var isTVGuide = false

    private struct TVLoading: Equatable {
        /// 同じ (日, 種別) の読みが重なっても、自分の後始末だけを消せるようにする
        let token: UUID
        let center: Date
        let type: ServiceType
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
    private func refresh() async {
        if isTVGuide {
            await tvReload(center: tvCenter ?? selectedDay, force: true)
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
    var tvTo: Int64 { GuideLayout.broadcastRange(for: tvDays.last ?? tvBase ?? selectedDay).to }

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

    /// 種別を切り替える。窓は TV 側が読み直す。読み込み中も今の表を出しておく
    /// (中心が読めない初回は、次の読みがそろうまで表が無い)
    func tvSelectType(_ type: ServiceType) {
        guard type != selectedType else { return }
        selectedType = type
        tvResponses = [:]
        // 読み込み中の旧い種別の応答を捨てる。走っている読みも dedupe の相手にしない
        // (種別を戻したときに、捨てるはずの読みへ吸われないように)
        tvGeneration += 1
        tvLoading.removeAll()
    }

    /// カーソルの放送日 (`center`) の前後 1 日ずつを、開いた日〜チップの最後の日の範囲で読み、
    /// 1 つの表につなぐ。持っていない日だけ読む (`force` なら持っている日も読み直す)。
    /// 先頭から連続して読めた日だけをつなぎ、足りない日は次の読みで取り直す。
    /// 中心が読めなかったときは今の表を差し替えない。適用したら `true` を返す
    @discardableResult
    func tvReload(center: Date, now: Date = Date(), force: Bool = false) async -> Bool {
        // 同じ日・同じ種別の読みが走っているなら重ねない (端の再試行で走っている読みを打ち切らない)。
        // 種別が変わっていれば別の読みなので、前の読みに飲まれずに読む
        if !force, tvLoading.contains(where: {
            GuideLayout.calendar.isDate($0.center, inSameDayAs: center) && $0.type == selectedType
        }) {
            return false
        }
        let loading = TVLoading(token: UUID(), center: center, type: selectedType)
        tvLoading.append(loading)
        defer {
            if let index = tvLoading.firstIndex(of: loading) { tvLoading.remove(at: index) }
        }
        tvGeneration += 1
        let generation = tvGeneration
        isTVGuide = true
        if tvBase == nil { tvBase = center }
        do {
            try await loadTypesIfNeeded()
        } catch {
            guard generation == tvGeneration else { return false }
            tvDidFail = true
            return false
        }
        guard generation == tvGeneration, let base = tvBase else { return false }
        let last = GuideLayout.menuDays(now: now, until: tvGuide?.until).last ?? base
        let days = GuideLayout.tvWindowDays(center: center, first: base, last: last)
        guard !days.isEmpty else { return false }
        var failed = false
        for day in days {
            let range = GuideLayout.broadcastRange(for: day)
            if !force, tvResponses[range.from] != nil { continue }
            do {
                let path = "api/programs?type=\(selectedType.rawValue)&from=\(range.from)&to=\(range.to)"
                let data = try await app.get(path)
                let decoded = try JSONDecoder().decode(GuideResponse.self, from: data)
                guard generation == tvGeneration else { return false }
                tvResponses[range.from] = decoded
            } catch {
                guard generation == tvGeneration else { return false }
                failed = true
            }
        }
        guard generation == tvGeneration else { return false }
        // 中心 (カーソルの日) が読めていないなら、いまの表をそのまま使う (1 日ぶん飛ばさない)。
        // まだ表が無い (初回) なら、別の日から始めずに失敗として出す
        if tvResponses[key(center)] == nil {
            if tvGuide == nil { tvDidFail = true }
            return false
        }
        let keys = Set(days.map { key($0) })
        tvResponses = tvResponses.filter { keys.contains($0.key) }
        // 途中に読めなかった日があれば、そこまでをつなぐ (間に空白を挟まない)
        let loaded = days.drop { tvResponses[key($0)] == nil }.prefix { tvResponses[key($0)] != nil }
        tvDays = Array(loaded)
        tvGuide = tvDays.isEmpty ? nil : Self.merge(tvDays.compactMap { tvResponses[key($0)] })
        tvDidFail = failed && tvGuide == nil
        // 採用した表の中心を覚える (追い越されて捨てられた読みでは動かさない)
        tvCenter = center
        return true
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
