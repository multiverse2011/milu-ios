import Foundation

/// 番組の詳細の時期 (3.5)。
enum ProgramTiming: Equatable, Sendable {
    /// これから (`now < startAt`)
    case future
    /// 放送中 (`startAt <= now < endAt`)
    case onAir
    /// 終わった (`endAt <= now`)
    case ended
}

/// 予約の状態 (api.md の `reservation.state`)。
enum ReservationState: String, Equatable, Sendable {
    case scheduled
    case recording
    case conflict
    case skipped
    case failed
    case missed
    case done
}

/// 番組の詳細のボタン (3.5 の表)。
enum ProgramButton: Equatable, Sendable {
    /// 「録画を予約」
    case reserve
    /// 「予約を取り消す」(赤)
    case cancelReservation
    /// 「ライブで観る」
    case watchLive
    /// 「● 録画する」
    case record
    /// 「● 録画中」(押すと確かめてから取り消す)
    case recordingNow

    nonisolated var title: String { title() }

    nonisolated func title(locale: Locale = .current) -> String {
        switch self {
        case .reserve: String(localized: LocalizedStringResource("録画を予約", locale: locale))
        case .cancelReservation: String(localized: LocalizedStringResource("予約を取り消す", locale: locale))
        case .watchLive: String(localized: LocalizedStringResource("ライブで観る", locale: locale))
        case .record: String(localized: LocalizedStringResource("● 録画する", locale: locale))
        case .recordingNow: String(localized: LocalizedStringResource("● 録画中", locale: locale))
        }
    }
}

/// 番組の詳細の状態の行 (3.5 の表)。色の当て方は画面側 (tint・赤・橙・控えた字)。
enum ProgramStatus: Equatable, Sendable {
    /// 放送中。`elapsedMs`・`totalMs` は進みのバーに使う
    case onAir(elapsedMs: Int64, totalMs: Int64)
    /// 「✓ 予約済み」(tint)
    case reserved
    /// 「⚠︎ 競合 · <reason>」(橙)
    case conflict(String)
    /// 控えた字の `reason` (`skipped` と、終わった番組の理由)
    case reason(String)

    /// 状態の行の字句
    nonisolated var text: String { text() }

    nonisolated func text(locale: Locale = .current) -> String {
        switch self {
        case .onAir(let elapsedMs, let totalMs):
            let rem = Wording.remaining(totalMs - elapsedMs, kind: .ago, locale: locale)
            return String(localized: LocalizedStringResource("放送中 · \(rem)", locale: locale))
        case .reserved:
            return String(localized: LocalizedStringResource("✓ 予約済み", locale: locale))
        case .conflict(let reason):
            return reason.isEmpty
                ? String(localized: LocalizedStringResource("⚠︎ 競合", locale: locale))
                : String(localized: LocalizedStringResource("⚠︎ 競合 · \(reason)", locale: locale))
        case .reason(let reason):
            return reason
        }
    }
}

/// 番組の詳細の状態の行とボタンの組 (3.5 の表を関数にしたもの)。
struct ProgramActionSet: Equatable, Sendable {
    var statuses: [ProgramStatus]
    var buttons: [ProgramButton]

    nonisolated init(statuses: [ProgramStatus], buttons: [ProgramButton]) {
        self.statuses = statuses
        self.buttons = buttons
    }

    /// 放送中の進みのバーを出すか
    nonisolated var showsProgress: Bool {
        statuses.contains { status in
            if case .onAir = status { return true }
            return false
        }
    }
}

/// 時期と `reservation.state` から、番組の詳細の状態の行とボタンを返す (3.5 の表)。
/// `reservation` は `reservation` オブジェクト (`state` と `reason`)。予約が無ければ `nil`。
/// `canWatchLive` が false のときは「ライブで観る」を出さない (局の id が引けない検索の番組。D31)
nonisolated func programActions(
    now: Date,
    startAt: Date,
    endAt: Date,
    reservation: (state: ReservationState, reason: String?)?,
    canWatchLive: Bool = true
) -> ProgramActionSet {
    func buttons(_ list: [ProgramButton]) -> [ProgramButton] {
        guard !canWatchLive else { return list }
        return list.filter { button in
            if case .watchLive = button { return false }
            return true
        }
    }
    let timing: ProgramTiming =
        now < startAt ? .future
        : now < endAt ? .onAir
        : .ended
    let state = reservation?.state

    switch timing {
    case .future:
        switch state {
        case .none, .failed, .missed, .done:
            return ProgramActionSet(statuses: [], buttons: [.reserve])
        case .scheduled, .recording:
            return ProgramActionSet(statuses: [.reserved], buttons: [.cancelReservation])
        case .conflict:
            return ProgramActionSet(statuses: [.conflict(reservation?.reason ?? "")], buttons: [.cancelReservation])
        case .skipped:
            return ProgramActionSet(statuses: [.reason(reservation?.reason ?? "")], buttons: [.reserve])
        }

    case .onAir:
        let elapsedMs = Int64(now.timeIntervalSince(startAt) * 1000)
        let totalMs = Int64(endAt.timeIntervalSince(startAt) * 1000)
        let onAir = ProgramStatus.onAir(elapsedMs: elapsedMs, totalMs: totalMs)
        switch state {
        case .none, .skipped, .failed, .missed, .done:
            return ProgramActionSet(statuses: [onAir], buttons: buttons([.watchLive, .record]))
        case .scheduled, .recording:
            return ProgramActionSet(statuses: [onAir], buttons: buttons([.watchLive, .recordingNow]))
        case .conflict:
            return ProgramActionSet(
                statuses: [onAir, .conflict(reservation?.reason ?? "")],
                buttons: buttons([.watchLive, .cancelReservation])
            )
        }

    case .ended:
        if let reason = reservation?.reason, !reason.isEmpty {
            return ProgramActionSet(statuses: [.reason(reason)], buttons: [])
        }
        return ProgramActionSet(statuses: [], buttons: [])
    }
}
