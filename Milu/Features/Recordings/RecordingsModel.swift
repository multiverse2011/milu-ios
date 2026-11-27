import Foundation
import Observation
import os

/// 録画のタブ (3.5)。一覧・絞り込み・削除・SSE の読み直し。
@Observable
@MainActor
final class RecordingsModel {
    enum Load: Equatable {
        case loading
        case ready
        case offline
        case empty
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case unseen

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "すべて")
            case .unseen: String(localized: "未視聴")
            }
        }
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")
    private static let pageSize = 50

    private(set) var load: Load = .loading
    private(set) var recordings: [Recording] = []
    private(set) var hasMore = false
    private(set) var services: [Int64: Service] = [:]
    var filter: Filter = .all
    var alertMessage: String?

    private var app: AppModel?
    private var subscriptions: [AppModel.Subscription] = []
    private var loading = false
    private var offset = 0

    var visible: [Recording] {
        guard filter == .unseen else { return recordings }
        return recordings.filter { $0.watchedAt == nil && $0.resumeMs == nil }
    }

    var sections: [Wording.DateSection<Recording>] {
        Wording.sections(of: visible, startAt: { Date(timeIntervalSince1970: Double($0.startAt) / 1000) }, reference: Date())
    }

    func start(_ app: AppModel) async {
        guard self.app == nil else { return }
        self.app = app
        subscriptions = [
            app.addEventListener { [weak self] event in
                guard event.event == "recordings" || event.event == "reservations" else { return }
                Task { await self?.refreshFromEvents() }
            },
            app.addReconnectListener { [weak self] in
                Task { await self?.reload() }
            },
        ]
        await loadServices()
        await reload()
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        app = nil
    }

    func reload() async {
        guard let app else { return }
        loading = true
        if recordings.isEmpty { load = .loading }
        do {
            let data = try await app.get("api/recordings?limit=\(Self.pageSize)&offset=0")
            let list = try JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: data)
            recordings = list
            offset = list.count
            hasMore = list.count == Self.pageSize
            load = list.isEmpty ? .empty : .ready
        } catch {
            if recordings.isEmpty { load = .offline }
            Self.logger.info("recordings を読めません: \(error.localizedDescription, privacy: .public)")
        }
        loading = false
        await fillUnseenIfNeeded()
    }

    /// 通知の `recordings`・`reservations`。取ってある件数ぶんを頭から取り直す (3.5.3)
    func refreshFromEvents() async {
        guard let app, !loading else { return }
        loading = true
        let limit = max(Self.pageSize, recordings.count)
        do {
            let data = try await app.get("api/recordings?limit=\(limit)&offset=0")
            let list = try JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: data)
            recordings = list
            offset = list.count
            hasMore = list.count == limit
            load = list.isEmpty ? .empty : .ready
        } catch {
            Self.logger.info("recordings の読み直しに失敗: \(error.localizedDescription, privacy: .public)")
        }
        loading = false
        await fillUnseenIfNeeded()
    }

    func loadMoreIfNeeded(current: Recording) async {
        guard hasMore, !loading, let index = visible.firstIndex(where: { $0.id == current.id }) else { return }
        guard index >= visible.count - 5 else { return }
        await loadMore()
    }

    func loadMore() async {
        guard let app, hasMore, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await app.get("api/recordings?limit=\(Self.pageSize)&offset=\(offset)")
            let list = try JSONDecoder().decodeArrayDroppingUnknowns([Recording].self, from: data)
            recordings.append(contentsOf: list)
            offset += list.count
            hasMore = list.count == Self.pageSize
        } catch {
            Self.logger.info("recordings の続きを読めません: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 「未視聴だけ」で画面が埋まらないうちは、末尾まで次の 50 件を取り続ける (3.5.3)
    private func fillUnseenIfNeeded() async {
        guard filter == .unseen else { return }
        // 画面が埋まるか、一覧の末尾まで来るまで取る (3.5.3)
        while hasMore, visible.count < 8 {
            let before = recordings.count
            await loadMore()
            guard recordings.count > before else { break }
        }
    }

    func setFilter(_ filter: Filter) async {
        self.filter = filter
        await fillUnseenIfNeeded()
    }

    func delete(_ recording: Recording) async -> String? {
        guard let app else { return String(localized: "denpa に接続されていません") }
        do {
            _ = try await app.delete("api/recordings/\(recording.id)")
            recordings.removeAll { $0.id == recording.id }
            // 一覧が 1 件縮んだぶん、次に読む所を詰める
            offset = max(0, offset - 1)
            if recordings.isEmpty { load = .empty }
            return nil
        } catch AppModel.APIError.http(_, let message) {
            return message ?? String(localized: "しばらくしてから、もう一度お試しください。")
        } catch {
            return String(localized: "しばらくしてから、もう一度お試しください。")
        }
    }

    func service(for serviceId: Int64) -> Service? {
        services[serviceId]
    }

    private func loadServices() async {
        guard let app else { return }
        do {
            let data = try await app.get("api/services")
            let list = try JSONDecoder().decodeArrayDroppingUnknowns([Service].self, from: data)
            services = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        } catch {
            Self.logger.info("service logos failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 一覧の行・詳細の組み立てに要る入力
    func entry(for recording: Recording) -> Wording.RecordingListEntry {
        Wording.RecordingListEntry(
            startAt: Date(timeIntervalSince1970: Double(recording.startAt) / 1000),
            endAt: Date(timeIntervalSince1970: Double(recording.endAt) / 1000),
            serviceName: recording.serviceName,
            recording: recording.recording,
            durationMs: recording.durationMs,
            resumeMs: recording.resumeMs
        )
    }
}
