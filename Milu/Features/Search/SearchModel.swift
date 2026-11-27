import Foundation
import Observation

/// 検索 (3.5・D31・D32)。打つたびに 0.3 秒待って `api/search` を読み、結果を持つ。
/// iPhone・iPad は録画の画面の中で `recordings` だけを使い、Apple TV は検索のタブで両方を使う。
/// 番組の詳細は番組表と同じシートを開くので、その受け手 (`ProgramSheetModel`) も兼ねる。
@Observable
@MainActor
final class SearchModel: ProgramSheetModel {
    enum Load: Equatable {
        /// 言葉が空
        case idle
        case loading
        case ready
        case empty
        case offline
    }

    /// `api/search` の 1 節の件数 (D31)
    nonisolated static let limit = 10
    /// 録画の一覧から本物の行を探すときの 1 ページと、探す上限 (D31)
    nonisolated static let recordingsPageSize = 100
    nonisolated static let recordingsPages = 20

    /// 録画を開く探索の結果。取り消し・接続先の変更は画面に何も出さない
    enum OpenResult: Equatable {
        case found(Recording)
        /// 一覧に見つからない・読めない
        case missing
        /// 新しい操作・言葉の変更・stop・接続先の変更で取り消された
        case cancelled
    }

    /// 画面が `fullScreenCover(item:)` で開く 1 本。モデルが検証してから置く
    struct OpenRequest: Identifiable {
        let id = UUID()
        let session: RecordingSession
    }

    private(set) var query = ""
    private(set) var load: Load = .idle
    private(set) var results: SearchResponse?
    /// 開く録画のセッション。画面はこれを見るだけ
    private(set) var openRequest: OpenRequest?
    /// 開けなかったときの alert の文言。画面はこれを見るだけ
    private(set) var openError: String?
    /// 局名 → 同じ名前の局 (検索の行は局の id を返さないので、一意に引けるときだけ使う)
    private var services: [String: [Service]] = [:]

    private var app: AppModel?
    /// 打ってから送るまでの待ち。テストは 0 にする
    private let debounce: Duration
    /// 問い合わせの世代。遅れて返った古い応答を捨てる
    private var generation = 0
    /// いちばん最後に適用した問い合わせの世代 (待った問い合わせが効いたかの判断に使う)
    private(set) var appliedGeneration = 0
    private var task: Task<Void, Never>?
    /// 送っている (0.3 秒の待ちを含む) 世代。通信が終わるまで値が入り、更新はこれを取り消さずに待つ
    private var pendingSend: Int?
    private var servicesTask: Task<Void, Never>?
    /// 局の一覧を読んだ接続先。替わったら捨てる
    private var servicesURL: URL?
    /// 録画の探索は 1 本だけ持つ。新しい操作・言葉の変更・stop・接続先の変更で取り消す
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0

    init(debounce: Duration = .milliseconds(300)) {
        self.debounce = debounce
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// iPhone・iPad が出す結果 (D32)。`recordings` だけで、番組だけが当たったら空の節。
    /// 言葉が空・まだ返っていない・失敗なら nil
    var recordingResults: SearchSection<SearchRecording>? {
        guard !trimmedQuery.isEmpty else { return nil }
        return results?.recordings
    }

    func start(_ app: AppModel) async {
        if let url = app.server?.url, let servicesURL, servicesURL != url {
            // 接続先が替わった。前の接続先の探索と局の一覧を捨てる
            cancelOpenExploration()
            services = [:]
        }
        self.app = app
        servicesTask?.cancel()
        let servicesTask = Task { [weak self] in
            guard let self else { return }
            await self.loadServices()
        }
        self.servicesTask = servicesTask
        if !trimmedQuery.isEmpty {
            // 画面へ戻ったとき、打ってあった言葉で探し直す
            await refresh()
        }
        await servicesTask.value
    }

    /// 検索のタスクだけを止める。`app` は残す (Apple TV の詳細のシートが開いている間も API を使う)
    func stop() {
        task?.cancel()
        task = nil
        pendingSend = nil
        servicesTask?.cancel()
        servicesTask = nil
        generation += 1
        cancelOpenExploration()
    }

    /// 入力の待ちタスク。テストが入力側の完了を待てるように返す
    @discardableResult
    func setQuery(_ value: String) -> Task<Void, Never>? {
        guard value != query else { return nil }
        query = value
        return schedule()
    }

    /// 繋がらないときの「再試行」。待たずに送り直す
    func retry() {
        guard let send = prepareSend(clearing: true) else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(send.word, generation: send.generation)
        }
        pendingSend = send.generation
    }

    /// 観る画面から戻ったとき・予約のあとの読み直し。送り終わるまで待つ。
    /// 待った問い合わせ自身が適用されたとき true。
    /// 遅れて呼ばれてもよいように、録画の探索は取り消さない。
    /// 同じ語の送信 (待ち・通信中) がまだ終わっていなければ、取り消さずにその結果を待つ。
    /// `joiningInFlight: false` は予約の確認用で、POST より前に送った GET を流用しない
    @discardableResult
    func refresh(joiningInFlight: Bool = true) async -> Bool {
        if joiningInFlight, let task, pendingSend == generation {
            let generation = self.generation
            await task.value
            return appliedGeneration == generation
        }
        guard let send = prepareSend(clearing: false, cancelsOpen: false) else { return false }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(send.word, generation: send.generation)
        }
        self.task = task
        pendingSend = send.generation
        await task.value
        return appliedGeneration == send.generation
    }

    // MARK: - 1 本の経路 (入力・更新・再試行)

    /// 送るたびに世代を上げ、前の問い合わせを取り消す。入力が変わったときは前の結果を消す。
    private func prepareSend(clearing: Bool, cancelsOpen: Bool = true) -> (word: String, generation: Int)? {
        task?.cancel()
        task = nil
        pendingSend = nil
        generation += 1
        if cancelsOpen { cancelOpenExploration() }
        let word = trimmedQuery
        guard !word.isEmpty, app != nil else {
            results = nil
            load = .idle
            return nil
        }
        if clearing { results = nil }
        load = .loading
        return (word, generation)
    }

    private func schedule() -> Task<Void, Never>? {
        guard let send = prepareSend(clearing: true) else { return nil }
        let debounce = debounce
        let task = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.perform(send.word, generation: send.generation)
        }
        self.task = task
        pendingSend = send.generation
        return task
    }

    private func perform(_ word: String, generation: Int) async {
        defer {
            if pendingSend == generation { pendingSend = nil }
        }
        guard let app else { return }
        do {
            let data = try await app.get(Self.path(query: word))
            guard Self.isCurrent(
                response: generation,
                current: self.generation,
                query: word,
                currentQuery: trimmedQuery
            ) else { return }
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            results = response
            load = response.isEmpty ? .empty : .ready
            appliedGeneration = generation
        } catch {
            guard Self.isCurrent(
                response: generation,
                current: self.generation,
                query: word,
                currentQuery: trimmedQuery
            ) else { return }
            results = nil
            load = .offline
            appliedGeneration = generation
        }
    }

    private func loadServices() async {
        guard let app, let url = app.server?.url else { return }
        if servicesURL != url {
            services = [:]
            servicesURL = url
        }
        guard services.isEmpty else { return }
        guard let data = try? await app.get("api/services") else { return }
        guard !Task.isCancelled, servicesURL == url, app.server?.url == url else { return }
        guard let list = try? JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data) else { return }
        services = Dictionary(grouping: list, by: { $0.name })
    }

    /// 同じ名前の局がちょうど 1 つのときだけ返す (取れていない・同名が複数・接続先が替わったら nil)
    private func service(named name: String) -> Service? {
        guard let app, let url = app.server?.url, servicesURL == url else { return nil }
        guard let matches = services[name], matches.count == 1 else { return nil }
        return matches[0]
    }

    // MARK: - 番組の詳細 (ProgramSheetModel)

    func programItem(_ row: SearchProgram) -> GuideProgramItem {
        GuideProgramItem(search: row, service: service(named: row.serviceName))
    }

    func program(id: Int64) -> GuideProgramItem? {
        guard let row = results?.programs.rows.first(where: { $0.id == id }) else { return nil }
        return programItem(row)
    }

    func detail(_ item: GuideProgramItem) async -> ProgramDetail? {
        guard let app else { return nil }
        guard let data = try? await app.get("api/programs/\(item.id)") else { return nil }
        return try? JSONDecoder().decode(ProgramDetail.self, from: data)
    }

    func reserve(_ item: GuideProgramItem) async -> String? {
        guard let app else { return String(localized: "denpa に接続されていません") }
        do {
            let data = try await app.post("api/programs/\(item.id)/record")
            guard let response = try? JSONDecoder().decode(RecordResponse.self, from: data) else {
                // 2xx でも本文が読めないときは決め打ちせず、検索を読み直して行とシートを合わせる。
                // 待った問い合わせが効いて、その番組の行が取れたときだけ確かめられたとみなす
                let applied = await refresh(joiningInFlight: false)
                let confirmed = applied && (results?.programs.rows.contains { $0.id == item.id } == true)
                return confirmed ? nil : String(localized: "予約の状態を確かめられませんでした。")
            }
            if !response.reserved {
                await refresh(joiningInFlight: false)
                return response.reason ?? String(localized: "録画できません")
            }
            setReservation(item.id, state: response.stateRaw ?? "scheduled")
            return nil
        } catch {
            return GuideModel.failureMessage(error)
        }
    }

    func cancel(_ item: GuideProgramItem) async -> String? {
        guard let app else { return String(localized: "denpa に接続されていません") }
        do {
            _ = try await app.delete("api/programs/\(item.id)/record")
            setReservation(item.id, state: nil)
            return nil
        } catch {
            return GuideModel.failureMessage(error)
        }
    }

    func watchLive(_ item: GuideProgramItem) {
        guard let serviceID = item.serviceID else { return }
        app?.requestLiveWatch(serviceID: serviceID)
    }

    /// 予約・取り消しのあと、詳細のシートが読む行を新しい状態にする。
    /// 成功したら世代を上げ、それより前に送った検索の応答で巻き戻さない
    private func setReservation(_ id: Int64, state: String?) {
        task?.cancel()
        task = nil
        pendingSend = nil
        generation += 1
        guard var response = results,
              let index = response.programs.rows.firstIndex(where: { $0.id == id })
        else { return }
        response.programs.rows[index].reservationState = state
        results = response
        load = response.isEmpty ? .empty : .ready
    }

    // MARK: - 録画を一覧から

    /// 検索の行の録画を、録画の一覧の本物の行として探して開く。押すたびに前の探索を取り消す。
    /// 一覧は新しい順なので大抵は 1 ページ目にある。20 ページで諦める。
    /// 検証とセッションの書き込みはモデルの中で同じ同期区間に行う (画面は結果を待たない)。
    func openRecording(id: Int64) async {
        cancelOpenExploration()
        openError = nil
        guard let app, let url = app.server?.url else { return }
        let generation = openGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.findRecording(id: id, from: url, generation: generation)
            self.applyOpenResult(result, generation: generation, from: url)
        }
        openTask = task
        await task.value
    }

    /// 探索の結果を画面の状態へ。検証と書き込みを同じ同期区間で行う
    func applyOpenResult(_ result: OpenResult, generation: Int, from url: URL) {
        guard isCurrent(generation, from: url) else { return }
        switch result {
        case .found(let recording):
            guard let session = session(for: recording) else {
                openError = String(localized: "この録画を開けませんでした。")
                return
            }
            openRequest = OpenRequest(session: session)
        case .missing:
            openError = String(localized: "この録画を開けませんでした。")
        case .cancelled:
            break
        }
    }

    /// 観る画面を閉じた。削除して戻ったなら、その行は読み直しを待たずに結果から外す。
    /// 削除より前に送った応答で行が戻らないよう、保留中の送信は無効にする
    func closeOpen(deletedID: Int64? = nil) {
        openRequest = nil
        guard let deletedID else { return }
        task?.cancel()
        task = nil
        pendingSend = nil
        generation += 1
        guard var response = results else { return }
        response.recordings.rows.removeAll { $0.id == deletedID }
        results = response
        load = response.isEmpty ? .empty : .ready
    }

    func clearOpenError() {
        openError = nil
    }

    /// 本物の行から、観る画面のセッションを組む (iPhone・iPad・Apple TV で同じ)
    func session(for recording: Recording) -> RecordingSession? {
        guard let app, let server = app.server else { return nil }
        return RecordingSession(
            baseURL: server.url,
            token: server.token,
            recording: recording,
            playable: Playable.formats,
            app: app,
            kind: recording.recording ? .chase : .recording
        )
    }

    private func cancelOpenExploration() {
        openTask?.cancel()
        openTask = nil
        openGeneration += 1
    }

    /// 取り消されていない・接続先が変わっていない
    private func isCurrent(_ generation: Int, from url: URL) -> Bool {
        !Task.isCancelled && generation == openGeneration && app?.server?.url == url
    }

    private func findRecording(id: Int64, from url: URL, generation: Int) async -> OpenResult {
        guard let app else { return .cancelled }
        for page in 0..<Self.recordingsPages {
            // 始まる前に取り消されていたら GET を送らない
            guard isCurrent(generation, from: url) else { return .cancelled }
            let offset = page * Self.recordingsPageSize
            let path = "api/recordings?limit=\(Self.recordingsPageSize)&offset=\(offset)"
            let data: Data
            do {
                data = try await app.get(path)
            } catch {
                return isCurrent(generation, from: url) ? .missing : .cancelled
            }
            guard isCurrent(generation, from: url) else { return .cancelled }
            // 照合はデコードできた録画で
            let list = try? JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: data)
            if let found = list?.first(where: { $0.id == id }) {
                guard isCurrent(generation, from: url) else { return .cancelled }
                return .found(found)
            }
            // 次のページへ進むかは、応答の配列の要素数で決める (デコードできたかによらない)
            let count = (try? JSONDecoder().decode([IgnoredJSON].self, from: data))?.count ?? 0
            if count < Self.recordingsPageSize {
                return isCurrent(generation, from: url) ? .missing : .cancelled
            }
        }
        return isCurrent(generation, from: url) ? .missing : .cancelled
    }

    /// 配列の要素数だけ数える (中身は読まない)
    private nonisolated struct IgnoredJSON: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

// MARK: - 純粋な部分 (テストする)

extension SearchModel {
    /// `api/search?q=&limit=`. 言葉は前後の空白を除いたものを URL に入れる。
    /// `+` は空白として読まれうるので、RFC 3986 の unreserved な字だけを残して percent-encode する
    nonisolated static func path(query: String, limit: Int = SearchModel.limit) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return "api/search?q=\(encoded)&limit=\(limit)"
    }

    /// 遅れて返った応答を捨てる判定。送ったときの世代と検索語が、いまのものと一致するときだけ使う
    nonisolated static func isCurrent(response generation: Int, current: Int, query: String, currentQuery: String) -> Bool {
        generation == current && query == currentQuery
    }

    /// 録画の行の 2 段目 (iPhone・iPad)。「11/14 (土) 13:00 · ほしぞら放送」。
    /// 観られない録画は「再生できません」を添える (D31)
    nonisolated static func recordingSubtitle(
        _ recording: SearchRecording,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let date = Wording.dateShort(start, calendar: calendar, locale: locale)
        let meta = "\(date) \(Wording.time(start, calendar: calendar)) · \(recording.serviceName)"
        guard recording.playable else {
            return String(localized: LocalizedStringResource("再生できません", locale: locale)) + " · " + meta
        }
        return meta
    }

    /// 録画のカードの 2 段目 (Apple TV)。「ほしぞら放送 · 11/14 (土) 13:00」
    nonisolated static func tvRecordingSubtitle(
        _ recording: SearchRecording,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let start = Date(timeIntervalSince1970: Double(recording.startAt) / 1000)
        let date = Wording.dateShort(start, calendar: calendar, locale: locale)
        let meta = "\(recording.serviceName) · \(date) \(Wording.time(start, calendar: calendar))"
        guard recording.playable else {
            return String(localized: LocalizedStringResource("再生できません", locale: locale)) + " · " + meta
        }
        return meta
    }

    /// 録画の行の 3 段目 (録画中だけ)。検索の行は終わりを持たないので「あと n 分」は出さない
    nonisolated static func recordingThird(
        _ recording: SearchRecording,
        locale: Locale = .current
    ) -> String? {
        recording.isRecording
            ? String(localized: LocalizedStringResource("● 録画中", locale: locale))
            : nil
    }

    /// 「これからの放送」の行の文言。左に `H:mm` と日付 (今日なら「今日」)、状態は予約済みか放送中 (3.5)
    nonisolated static func programRowText(
        _ program: SearchProgram,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SearchProgramRowText {
        let start = Date(timeIntervalSince1970: Double(program.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(program.endAt) / 1000)
        let day = calendar.isDate(start, inSameDayAs: now)
            ? String(localized: LocalizedStringResource("今日", locale: locale))
            : Wording.dateShort(start, calendar: calendar, locale: locale)
        let state: SearchProgramRowText.State?
        if start <= now, now < end {
            state = .onAir
        } else if program.reservationState == "scheduled" || program.reservationState == "recording" {
            state = .reserved
        } else {
            state = nil
        }
        return SearchProgramRowText(
            time: Wording.time(start, calendar: calendar),
            day: day,
            state: state
        )
    }
}

/// 「これからの放送」の行の文言
struct SearchProgramRowText: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case reserved
        case onAir

        func text(locale: Locale = .current) -> String {
            switch self {
            case .reserved: String(localized: LocalizedStringResource("予約済み", locale: locale))
            case .onAir: String(localized: LocalizedStringResource("● 放送中", locale: locale))
            }
        }
    }

    var time: String
    var day: String
    var state: State?
}

// MARK: - 検索の行

extension SearchRecording {
    /// 一覧のサムネイルの相対 URL。検索の行はこの値を返さないので、一覧と同じ道から組む
    nonisolated var posterPath: String {
        "api/recordings/\(id)/poster"
    }

    nonisolated var isRecording: Bool {
        state == "recording"
    }

    /// 観る画面を開けるか (`watch` が null なら観られない)
    nonisolated var playable: Bool {
        watch != nil
    }
}

extension GuideProgramItem {
    /// 検索の候補の行から。`api/search` は局の id・ロゴ・ジャンル・説明を返さないので、
    /// 局は名前が一意に引けたときだけ埋める (引けなければ「ライブで観る」を出さない)
    nonisolated init(search row: SearchProgram, service: Service?) {
        self.id = row.id
        self.serviceID = service?.id
        self.serviceName = row.serviceName
        self.logo = service?.logo
        self.remoteControlKey = service?.remoteControlKey
        self.name = row.name
        self.description = nil
        self.startAt = row.startAt
        self.endAt = row.endAt
        self.genre = nil
        self.reservation = row.reservationState.map {
            ReservationInfo(stateRaw: $0, reason: nil, ruleId: nil)
        }
    }
}
