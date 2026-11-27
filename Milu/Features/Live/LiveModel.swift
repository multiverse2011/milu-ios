import Foundation
import Observation
import os

/// `api/playback/options` のうちライブで要るもの。`liveCodecs` が無い古い denpa でも読める (6 節)。
nonisolated struct LiveOptions: Decodable, Sendable {
    var liveCodecs: [OfferCodec] = []
    var hevc = false

    nonisolated init() {}

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liveCodecs = container.decodeDroppingUnknowns([OfferCodec].self, forKey: .liveCodecs)
        hevc = (try? container.decode(Bool.self, forKey: .hevc)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case liveCodecs, hevc
    }
}

/// ライブのタブ (3.5)。局の一覧・種別・いまの番組・録画・再生の画面をまとめる。
@Observable
@MainActor
final class LiveModel {
    enum Load: Equatable {
        case loading
        case ready
        case offline
        case empty
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    private(set) var load: Load = .loading
    private(set) var services: [Service] = []
    private(set) var types: [ServiceType] = []
    private(set) var current: Service?
    /// いまの番組の短い説明 (iPad-Live の映像の下)
    private(set) var currentDescription = ""
    /// いまの番組の中身 (TV-LiveDetail。`api/programs/<id>` の応答)
    private(set) var currentDetail: ProgramDetail?
    private(set) var session: PlaybackSession?
    var selectedType: ServiceType = .GR
    var showFullscreen = false
    var controlsVisible = true
    var recordAlert: String?
    var showStopRecording = false
    var menuHoldUntil = Date.distantPast

    private var app: AppModel?
    private let nowPlaying: NowPlayingController
    private var subscriptions: [AppModel.Subscription] = []
    private var options = LiveOptions()
    private let defaults: UserDefaults
    private let isPhone: Bool
    private var hideTask: Task<Void, Never>?
    private var descriptionTask: Task<Void, Never>?
    /// 説明を読んだ番組。同じ番組なら読み直さず、空にもしない
    private var descriptionProgramId: Int64?
    private(set) var started = false
    private var playbackOpen = false
    /// 再生の画面を閉じた (tvOS)。一覧が空になって局が戻っても、勝手に開き直さない
    private var playbackSuspended = false

    /// 再生の画面が開いているか (tvOS の cover の出し入れ。iOS では再生中)
    var isPlaybackOpen: Bool { playbackOpen }

    private var backgrounded = false
    /// タブに入ったとき・番組表の「ライブで観る」で立て、次の再生開始で使い切る
    private var pendingAutoFullscreen = true
    private var pendingWatch: Int64?

    init(
        defaults: UserDefaults = .standard,
        isPhone: Bool = DeviceName.isPhone,
        nowPlaying: NowPlayingController = .shared
    ) {
        self.defaults = defaults
        self.isPhone = isPhone
        self.nowPlaying = nowPlaying
    }

    /// タブの選択とアプリの前後から、接続を開く・保つ・閉じるをまとめて決める (#32・a901338)
    func handleLifecycle(isSelected: Bool, appPhase: PlaybackRules.AppPhase, app: AppModel) {
        switch PlaybackRules.liveLifecycleAction(
            isSelected: isSelected,
            appPhase: appPhase,
            started: started,
            sessionPhase: session?.phase,
            pictureInPicture: session?.pictureInPictureActive ?? false
        ) {
        case .activate:
            let wasBackgrounded = backgrounded
            backgrounded = false
            session?.setBackground(false)
            if !started {
                Task { await start(app) }
            } else if wasBackgrounded {
                Task { await reload() }
            }
        case .keepInBackground:
            backgrounded = true
            session?.setBackground(true)
        case .stop:
            backgrounded = false
            showFullscreen = false
            stop()
        case .none:
            break
        }
    }

    func start(_ app: AppModel) async {
        guard !started else { return }
        started = true
        self.app = app
        subscriptions = [
            app.addEventListener { [weak self] event in self?.handle(event) },
            app.addReconnectListener { [weak self] in
                Task { await self?.reload() }
            },
        ]
        await loadOptions()
        await loadServices(initial: true)
        guard started, self.app != nil else { return }
        // 「ライブで観る」が start より先に届いていたら、loadServices の中で applyPendingWatch が
        // 開いている。同じ局を続けて 2 回 open しない (#72)
        // 一覧で再生を止めたまま裏へ回って戻ったときは、開き直さない (#72)
        if load == .ready, !playbackOpen, !playbackSuspended {
            openCurrent()
        }
    }


    func stop() {
        started = false
        playbackOpen = false
        backgrounded = false
        showFullscreen = false
        hideTask?.cancel()
        hideTask = nil
        descriptionTask?.cancel()
        descriptionTask = nil
        descriptionProgramId = nil
        currentDescription = ""
        currentDetail = nil
        session?.close()
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        app = nil
    }

    func reload() async {
        guard started, app != nil else { return }
        await loadServices(initial: services.isEmpty)
        // 読んでいる間に stop されたら、閉じた接続を開き直さない
        guard started, app != nil else { return }
        if load == .ready {
            if let current, services.contains(where: { $0.id == current.id }) {
                if session == nil || session?.phase == .idle {
                    // 再生の画面を閉じて一覧を出している間は、SSE の一覧更新で勝手に開き直さない
                    if !playbackSuspended {
                        openCurrent()
                    }
                } else {
                    saveLast(current)
                    session?.updateService(current)
                }
            } else if let first = services.first {
                current = first
                selectedType = first.type
                saveLast(first)
                // ロック画面などで一時停止している間に観ていた局が放送休止になっても、別の局を勝手に鳴らし始めない
                if session?.phase == .paused {
                    session?.updateService(first)
                } else if !playbackSuspended {
                    playbackOpen = true
                    session?.open(first, liveCodecs: options.liveCodecs)
                }
            } else {
                if session?.phase != .paused {
                    playbackOpen = false
                    session?.close()
                }
                current = nil
                load = .empty
            }
        } else if load == .empty {
            // 一時停止中に 0 件になっても close せず、局が戻ったときに updateService だけで済ませて勝手に鳴らし始めない
            if session?.phase != .paused {
                playbackOpen = false
                session?.close()
            }
            current = nil
        }
    }

    /// ライブのタブに入り直したときだけ、次の再生開始で自動全画面を効かせる (scenePhase の復帰と区別する)
    func setTabSelected(_ selected: Bool) {
        // タブを離れるときは何もしない (再生開始で使い切っており、入り直すときに true を立て直す)
        if selected {
            pendingAutoFullscreen = true
            // 一覧で止めた再生も、タブに入り直したら始め直す (裏へ回っただけでは始めない。#72)
            playbackSuspended = false
        }
    }

    /// 選んだ局の再生を開く。tvOS の再生画面を開き直すときと、番組表の「ライブで観る」が使う。
    /// 一覧の `select` と違い、`current` が同じ局でも開き直す
    func openPlayback(_ service: Service) {
        guard makeSession() else { return }
        // 閉じている間に届いた古い知らせを持ち越さない (#72)
        recordAlert = nil
        showStopRecording = false
        current = service
        selectedType = service.type
        saveLast(service)
        playbackOpen = true
        playbackSuspended = false
        session?.open(service, liveCodecs: options.liveCodecs)
        loadDescription()
    }

    /// 再生だけを閉じて局の一覧に戻す (tvOS で再生の画面を閉じたとき)。
    /// モデルは開いたままにして、一覧と SSE はそのまま使えるようにする
    func closePlayback() {
        guard playbackOpen else { return }
        playbackOpen = false
        playbackSuspended = true
        // 再生の画面が無いと出せない知らせは落とす (次に開いたときに古いものを出さない) (#72)
        recordAlert = nil
        showStopRecording = false
        hideTask?.cancel()
        hideTask = nil
        session?.close()
    }

    func select(_ service: Service) {
        if service.id == current?.id {
            if session?.phase == .paused {
                _ = session?.play()
                enterFullscreenIfNeeded()
            }
            return
        }
        current = service
        selectedType = service.type
        saveLast(service)
        // start の途中で applyPendingWatch から呼ばれたときは、まだ開いていないので openCurrent に任せる
        guard playbackOpen else { return }
        pendingAutoFullscreen = false
        session?.open(service, liveCodecs: options.liveCodecs)
        loadDescription()
        enterFullscreenIfNeeded()
    }

    /// 番組表の「ライブで観る」。局の一覧を読み終えていなければ、読み終えてから映す。
    func watch(serviceID: Int64) {
        pendingWatch = serviceID
        pendingAutoFullscreen = true
        applyPendingWatch()
    }

    private func applyPendingWatch() {
        // 止まっている間 (stop のあと) に届いたものは、start の loadServices から改めて適用する。
        // ここで開くと app が無いまま開いて、説明・詳細を取りこぼす (#72)
        guard started, app != nil else { return }
        guard let id = pendingWatch, let service = services.first(where: { $0.id == id }) else { return }
        pendingWatch = nil
        if service.id == current?.id, playbackOpen {
            if session?.phase == .paused {
                _ = session?.play()
            }
            pendingAutoFullscreen = false
            enterFullscreenIfNeeded()
        } else {
            // 再生を閉じていても、番組表の「ライブで観る」なら開く
            pendingAutoFullscreen = false
            openPlayback(service)
            enterFullscreenIfNeeded()
        }
    }

    func selectQuality(_ codec: OfferCodec?) {
        session?.selectQuality(codec)
    }

    func selectRung(_ rung: Int) {
        session?.selectRung(rung)
    }

    func selectAudio(_ track: AudioTrack) {
        session?.selectAudio(track)
    }

    func setCaptionsOn(_ on: Bool) {
        session?.setCaptionsOn(on)
    }

    /// 決定・再生/一時停止ボタン。ライブの一時停止は接続を閉じ、再開はその時点のライブ (D17)。
    /// Now Playing の経路と二重に効かないことは `PlaybackSession` が受け止める
    @discardableResult
    func togglePlayPause() -> Bool {
        session?.togglePlayPause() ?? false
    }

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleHide()
        } else {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    func noteMenuInteraction() {
        menuHoldUntil = Date().addingTimeInterval(10)
        showControls()
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = nil
        guard session?.phase == .playing else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, Date() >= self.menuHoldUntil else { return }
            self.controlsVisible = false
        }
    }

    func toggleRecord() {
        guard let current, let now = current.now else { return }
        if now.reserved || now.recording {
            showStopRecording = true
        } else {
            Task { await startRecording(service: current) }
        }
    }

    func stopRecording() {
        guard let app, let now = current?.now else { return }
        Task {
            do {
                _ = try await app.delete("api/programs/\(now.id)/record")
                await reload()
            } catch let error as AppModel.APIError {
                recordAlert = message(error)
            } catch {
                recordAlert = String(localized: "録画を停止できません")
            }
        }
    }

    func retry() {
        session?.retry()
    }

    func handle(_ event: SSEEvent) {
        switch event.event {
        case "services", "programs", "recordings", "reservations":
            Task { await reload() }
        case "yielded":
            guard
                let data = event.data.data(using: .utf8),
                let yielded = try? JSONDecoder().decode(Yielded.self, from: data),
                yielded.serviceId == current?.id
            else { return }
            session?.yielded()
        default:
            break
        }
    }

    // MARK: - 読み込み

    private func loadOptions() async {
        guard let app else { return }
        do {
            let data = try await app.get("api/playback/options")
            options = try JSONDecoder().decode(LiveOptions.self, from: data)
            if options.liveCodecs.isEmpty {
                Self.logger.info("liveCodecs がありません")
            }
        } catch {
            options = LiveOptions()
            Self.logger.info("playback/options を読めません")
        }
    }

    private func loadServices(initial: Bool) async {
        guard let app else { return }
        do {
            let data = try await app.get("api/services")
            let all = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data)
            let eligible = all.filter { $0.airing && $0.video }
            services = eligible
            types = ServiceType.allCases.filter { type in
                eligible.contains { $0.type == type }
            }
            if initial || current == nil {
                let saved = lastServiceID
                current = eligible.first { $0.id == saved } ?? eligible.first
            } else if let id = current?.id {
                current = eligible.first { $0.id == id }
            }
            if let current {
                selectedType = current.type
            }
            if eligible.isEmpty {
                load = .empty
            } else if initial || load == .loading || load == .empty {
                load = .ready
            }
            applyPendingWatch()
            loadDescription()
        } catch {
            if services.isEmpty {
                load = .offline
            }
            Self.logger.info("services を読めません: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 再生のセッションを用意する (無ければ作る)。接続先が無ければ false
    private func makeSession() -> Bool {
        if session != nil { return true }
        guard let app, let server = app.server else { return false }
        session = PlaybackSession(
            baseURL: server.url,
            token: server.token,
            defaults: defaults,
            nowPlaying: nowPlaying,
            onInvalidToken: { [weak app] url in app?.discardToken(for: url) },
            onNeedsPairing: { [weak app] url in app?.requirePairing(for: url) }
        )
        return true
    }

    private func openCurrent() {
        guard let current, makeSession() else { return }
        playbackOpen = true
        playbackSuspended = false
        session?.open(current, liveCodecs: options.liveCodecs)
        saveLast(current)
        loadDescription()
        if pendingAutoFullscreen {
            pendingAutoFullscreen = false
            enterFullscreenIfNeeded()
        }
    }

    private func enterFullscreenIfNeeded() {
        // 端末の向きは iPhone だけ (3.5.3)。tvOS はテレビの画面を回さない
        #if os(iOS)
        guard OrientationLock.shouldAutoLandscape(defaults: defaults, isPhone: isPhone) else { return }
        OrientationLock.shared.lock(.landscape, isPhone: isPhone)
        showFullscreen = true
        #endif
    }

    private func loadDescription() {
        // 同じ番組なら、一覧の読み直し (SSE の programs・recordings など) で消さず取り直さない
        let id = current?.now?.id
        guard id != descriptionProgramId else { return }
        descriptionTask?.cancel()
        descriptionProgramId = id
        currentDescription = ""
        currentDetail = nil
        guard let app, let id else { return }
        descriptionTask = Task { [weak self] in
            guard
                let data = try? await app.get("api/programs/\(id)"),
                let detail = try? JSONDecoder().decode(ProgramDetail.self, from: data),
                !Task.isCancelled,
                self?.descriptionProgramId == id
            else { return }
            self?.currentDescription = detail.description ?? ""
            self?.currentDetail = detail
        }
    }

    private func startRecording(service: Service) async {
        guard let app else { return }
        do {
            let data = try await app.post("api/services/\(service.id)/record")
            let response = try JSONDecoder().decode(RecordResponse.self, from: data)
            if !response.reserved {
                recordAlert = response.reason ?? String(localized: "しばらくしてから、もう一度お試しください。")
            }
            await reload()
        } catch let error as AppModel.APIError {
            recordAlert = message(error)
        } catch {
            recordAlert = String(localized: "しばらくしてから、もう一度お試しください。")
        }
    }

    private func message(_ error: AppModel.APIError) -> String {
        switch error {
        case .http(_, let message): message ?? String(localized: "しばらくしてから、もう一度お試しください。")
        case .network: String(localized: "denpa に接続できません")
        case .notConnected: String(localized: "denpa に接続されていません")
        case .needsPairing: ""
        case .decoding: String(localized: "denpa からの応答を読み取れませんでした")
        }
    }

    private var lastServiceID: Int64? {
        let value = defaults.integer(forKey: "lastServiceID")
        return value == 0 ? nil : Int64(value)
    }

    private func saveLast(_ service: Service) {
        defaults.set(Int(service.id), forKey: "lastServiceID")
    }

    private struct Yielded: Decodable {
        let serviceId: Int64
    }
}

extension ServiceType {
    var title: String {
        GuideText.typeLabel(self)
    }
}
