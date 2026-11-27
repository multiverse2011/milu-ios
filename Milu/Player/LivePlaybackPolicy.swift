import Foundation

/// ライブの繋ぎ直しの分岐 (3.3)。通信・時計を外から受ける純粋な型。
/// `PlaybackSession` がイベントを渡し、返ってきた行動を実行する。
nonisolated enum LiveEvent: Equatable, Sendable {
    /// 200 の応答を受け取った
    case response
    /// 最初のコマが出た
    case firstFrame
    /// 200 で中身を送ったあと、サーバが閉じた
    case closed
    /// 200 のまま中身が 1 つも来ずに閉じた
    case empty
    /// 読めない (通信が切れた・5xx など)
    case failed(status: Int?, message: String?, errorCode: String?)
    /// 10 秒進まない
    case stalled
    /// 端末でデコードできない
    case decodeFailed(codec: OfferCodec)
    /// SSE の `yielded` (チューナーを録画に譲った)
    case yielded
}

nonisolated enum LiveStopReason: Equatable, Sendable {
    case noPlayableFormat
    case serverBusy
    case emptyStream
    case yielded
    case refused(String)
}

nonisolated enum LiveAction: Equatable, Sendable {
    case restartNow
    case restart(after: Double)
    case resetWait
    case removeCodec(OfferCodec)
    case stop(LiveStopReason, retry: Bool)
}

nonisolated struct LivePlaybackPolicy: Sendable {
    private(set) var playable: [OfferCodec]
    private(set) var currentCodec: OfferCodec?
    private var wait = PlaybackRules.ReconnectTimer()
    private var lastClosedAt: Date?
    private var emptyCount = 0
    private var busyCount = 0
    private var yieldedAt: Date?
    private var yieldedFailures = 0

    nonisolated init(playable: [OfferCodec], currentCodec: OfferCodec? = nil) {
        self.playable = playable
        self.currentCodec = currentCodec
    }

    nonisolated mutating func handle(_ event: LiveEvent, at now: Date) -> [LiveAction] {
        switch event {
        case .response:
            busyCount = 0
            emptyCount = 0
            return []

        case .firstFrame:
            wait.reset()
            busyCount = 0
            emptyCount = 0
            yieldedAt = nil
            yieldedFailures = 0
            return [.resetWait]

        case .closed:
            var actions: [LiveAction] = []
            if let last = lastClosedAt, now.timeIntervalSince(last) <= 30 {
                actions.append(.restart(after: wait.advance()))
            } else {
                wait.reset()
                actions.append(.restartNow)
            }
            lastClosedAt = now
            actions.append(contentsOf: yieldedFailure(now: now))
            return actions

        case .empty:
            emptyCount += 1
            var actions: [LiveAction] = []
            if emptyCount <= 3 {
                actions.append(.restart(after: wait.advance()))
            } else {
                actions.append(.stop(.emptyStream, retry: true))
            }
            actions.append(contentsOf: yieldedFailure(now: now))
            return actions

        case .failed(let status, let message, _):
            var actions: [LiveAction]
            switch status {
            case 406:
                // 同じ P で取り直しても同じ 406 になる (3.3)
                actions = [.stop(.noPlayableFormat, retry: false)]
            case 404, 409:
                actions = [.stop(.refused(message ?? String(localized: "再生できません")), retry: true)]
            case 503 where message == "サーバが混んでいます":
                if busyCount < 3 {
                    busyCount += 1
                    actions = [.restart(after: wait.advance())]
                } else {
                    actions = [.stop(.serverBusy, retry: true)]
                }
            default:
                // ほかの 5xx・通信のエラーは上限なく待ちを伸ばして試し直す
                actions = [.restart(after: wait.advance())]
            }
            actions.append(contentsOf: yieldedFailure(now: now))
            return actions

        case .stalled:
            return [.restart(after: wait.advance())]

        case .decodeFailed(let codec):
            // 使っていない形式の失敗では P を触らない
            guard playable.contains(codec) else { return [] }
            playable.removeAll { $0 == codec }
            if currentCodec == codec { currentCodec = nil }
            if playable.isEmpty {
                return [.removeCodec(codec), .stop(.noPlayableFormat, retry: false)]
            }
            return [.removeCodec(codec), .restartNow]

        case .yielded:
            yieldedAt = now
            yieldedFailures = 0
            return []
        }
    }

    /// `yielded` を受けてから 60 秒以内に 3 回続けて映らなければ止める (D24)。
    private mutating func yieldedFailure(now: Date) -> [LiveAction] {
        guard let yieldedAt, now.timeIntervalSince(yieldedAt) <= 60 else { return [] }
        yieldedFailures += 1
        if yieldedFailures >= 3 {
            return [.stop(.yielded, retry: true)]
        }
        return []
    }
}
