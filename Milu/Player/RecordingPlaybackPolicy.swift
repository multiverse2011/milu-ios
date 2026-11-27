import Foundation

/// 録画を観ているときの繋ぎ直し (3.3 の表の録画に掛かる行)。純粋な型。
enum RecordingEvent: Equatable, Sendable {
    /// `stream` が尺の手前で閉じた (一時停止して 5 分たち、サーバが変換を止めたときも)
    case closed
    /// 200 のまま中身が空で閉じた
    case empty
    case failed(status: Int?, message: String?, errorCode: String?)
    case stalled
    case decodeFailed(codec: OfferCodec)
}

enum RecordingStopReason: Equatable, Sendable {
    case noPlayableFormat
    case noVideo
    case serverBusy
    case emptyStream
    case refused(String)
}

enum RecordingAction: Equatable, Sendable {
    case end
    case reopen(from: Double, after: Double)
    case removeCodec(OfferCodec)
    case stop(RecordingStopReason, retry: Bool)
}

/// 録画の繋ぎ直し。待ちは 1 秒から倍々で上限 10 秒。最初のコマが映ったら 1 秒に戻す。
struct RecordingPlaybackPolicy: Equatable, Sendable {
    private(set) var playable: [OfferCodec]
    private var timer = PlaybackRules.ReconnectTimer()
    private var busyCount = 0
    private var emptyCount = 0
    /// 直前に閉じた位置。同じ所で続けて閉じたら待ちを伸ばす
    private var lastClosedPosition: Double?

    nonisolated init(playable: [OfferCodec]) {
        self.playable = playable
    }

    /// 最初のコマが映ったら、待ちと回数を戻す。
    /// ただし直前と同じ位置で閉じ続けているときは、待ちを伸ばしたままにする
    nonisolated mutating func firstFrame(at position: Double) {
        busyCount = 0
        emptyCount = 0
        if let last = lastClosedPosition, position <= last + 1 {
            return
        }
        timer.reset()
        lastClosedPosition = nil
    }

    /// `position` はいま観ている位置 (秒)。リクエストし直すときはそこから開く。
    nonisolated mutating func handle(
        _ event: RecordingEvent,
        position: Double,
        duration: Double
    ) -> [RecordingAction] {
        switch event {
        case .closed:
            // 尺の手前で閉じたのは、サーバが変換を止めたとき (3.3)。ただし末尾 5 秒で閉じたのは
            // 録画の終わり (ファイルの尺と最後のコマが数秒ずれる) なので、終わりとして扱う
            if RecordingRules.isFinished(position: position, duration: duration)
                || (duration > 0 && duration - position <= 5) {
                return [.end]
            }
            // 同じ位置で続けて閉じるなら、休みなく開き直さず待ちを伸ばす (ライブの 30 秒以内と同じ)
            let repeated = lastClosedPosition.map { abs(position - $0) <= 1 } ?? false
            lastClosedPosition = position
            if repeated {
                return [.reopen(from: position, after: timer.advance())]
            }
            timer.reset()
            return [.reopen(from: position, after: 0)]

        case .empty:
            emptyCount += 1
            if emptyCount > 3 {
                return [.stop(.emptyStream, retry: true)]
            }
            return [.reopen(from: position, after: timer.advance())]

        case .failed(let status, let message, _) where status == 503 && Self.isBusy(message):
            busyCount += 1
            if busyCount > 3 {
                return [.stop(.serverBusy, retry: true)]
            }
            return [.reopen(from: position, after: timer.advance())]

        case .failed(status: 406, message: _, errorCode: _):
            // 同じ offers で取り直しても同じ 406 になる (3.3)
            return [.stop(.noPlayableFormat, retry: false)]

        case .failed(let status, let message, _) where status == 404 || status == 409:
            return [.stop(.refused(message ?? String(localized: "再生できません")), retry: false)]

        case .failed:
            return [.reopen(from: position, after: timer.advance())]

        case .stalled:
            return [.reopen(from: position, after: timer.advance())]

        case .decodeFailed(let codec):
            guard playable.contains(codec) else { return [] }
            playable.removeAll { $0 == codec }
            if playable.isEmpty {
                return [.removeCodec(codec), .stop(.noPlayableFormat, retry: false)]
            }
            return [.removeCodec(codec), .reopen(from: position, after: 0)]
        }
    }

    nonisolated static func isBusy(_ message: String?) -> Bool {
        message == "サーバが混んでいます"
    }
}
