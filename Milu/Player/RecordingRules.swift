import CoreMedia
import Foundation

/// 録画を観るときの決まりのうち、純粋に書けるもの (3.3・3.5)。
enum RecordingRules {
    /// 続きから観る位置 (秒)。`resumeMs` が無ければ頭から
    nonisolated static func startPosition(resumeMs: Int64?) -> Double {
        guard let resumeMs else { return 0 }
        return max(0, Double(resumeMs) / 1000)
    }

    /// 10 秒戻す・送るの行き先。尺の外へは出さない
    nonisolated static func seek(_ position: Double, by delta: Double, duration: Double) -> Double {
        min(max(0, position + delta), max(0, duration))
    }

    /// 「次のチャプター」の行き先。いまより後ろで一番近いチャプターの頭。無ければ `nil`
    nonisolated static func nextChapter(chapters: [Chapter], position: Double) -> Double? {
        chapters.map(\.start).filter { $0 > position + 0.5 }.min()
    }

    /// いまの位置があるチャプターの題 (TV-Player の左下の「本編」)。
    /// どの区間にも入っていないとき (区間の隙間・最後の区間のあと) は直前のチャプターの題。先頭より前なら `nil`
    nonisolated static func chapterTitle(chapters: [Chapter], position: Double) -> String? {
        if let current = chapters.first(where: { $0.start <= position && position < $0.end }) {
            return current.title
        }
        return chapters.last { $0.start <= position }?.title
    }

    /// 詳細の「続きから再生」の位置 (ms)。再生の画面から開いたときはその位置 (`override`)、
    /// 一覧から開いたときは保存された位置 (`saved`)。1 秒未満 (観はじめ) は「再生」に倒して `nil`
    nonisolated static func detailResumeMs(override: Int64?, saved: Int64?) -> Int64? {
        guard let value = override ?? saved, value >= 1000 else { return nil }
        return value
    }

    /// 最後まで観たか。尺の終わりに着いたら「最後まで観ました」にする
    nonisolated static func isFinished(position: Double, duration: Double) -> Bool {
        duration > 0 && position >= duration - 0.3
    }

    /// 追っかけで録れている所 (秒)。位置 + 溜まっている秒。予定の長さを超えない
    nonisolated static func recordedThrough(position: Double, buffered: Double, scheduled: Double) -> Double {
        let end = position + buffered
        return scheduled > 0 ? min(end, scheduled) : end
    }

    /// 「最新」の行き先。録れている所の 3 秒手前 (3.5.3)
    nonisolated static func latestPosition(recordedThrough: Double) -> Double {
        max(0, recordedThrough - 3)
    }

    /// 「最新」は進むだけ。いまより後ろへは戻さない
    nonisolated static func latestTarget(position: Double, recordedThrough: Double) -> Double {
        max(position, latestPosition(recordedThrough: recordedThrough))
    }

    /// 追っかけを開いたときの「録れている所」の見積り。
    /// 録画の先頭の放送時刻 (`jikkyo.head`) からの経過時間 (予定の長さで頭打ち)。
    /// 番組の途中から録った録画を取り違えないよう、番組の始まりは使わない。
    /// `head` が無ければ見積もらない
    nonisolated static func elapsedThrough(headMs: Int64?, now: Date, scheduled: Double) -> Double {
        guard let headMs else { return 0 }
        let elapsed = max(0, now.timeIntervalSince1970 - Double(headMs) / 1000)
        return scheduled > 0 ? min(scheduled, elapsed) : elapsed
    }

    /// 2 倍で録れている所の 3 秒手前まで追いついたか (3.5.3)
    nonisolated static func caughtUp(position: Double, recordedThrough: Double) -> Bool {
        position >= recordedThrough - 3
    }

    /// 追っかけが閉じたときに「最後まで観た」か。状態の `durationMs` があり、
    /// 観ている位置が末尾 5 秒以内なら終わり
    nonisolated static func chaseFinished(position: Double, durationMs: Int64?) -> Bool {
        guard let durationMs, durationMs > 0 else { return false }
        return position >= Double(durationMs) / 1000 - 5
    }

    /// 観た割合 (0...1)。録画中で尺が無ければ 0
    nonisolated static func watchedFraction(resumeMs: Int64?, durationMs: Int64?) -> Double {
        guard let resumeMs, let durationMs, durationMs > 0 else { return 0 }
        return min(1, max(0, Double(resumeMs) / Double(durationMs)))
    }

    /// 選べる音声のうち最初に使うもの。覚えた名前 (`label`) があればそれ。無ければ先頭。
    nonisolated static func pickAudio(_ audios: [PlaybackAudio], savedName: String?) -> PlaybackAudio? {
        if let savedName, let match = audios.first(where: { $0.label == savedName }) {
            return match
        }
        return audios.first
    }

    /// 録画 (`playback.audios`) と追っかけ (`recordings.audios`) を同じ形で扱う
    struct AudioChoice: Identifiable, Equatable, Sendable {
        var id: String
        var label: String
        /// 追っかけだけ分かる (主音声か)
        var main: Bool?

        nonisolated init(_ audio: PlaybackAudio) {
            id = audio.id
            label = audio.label
            main = nil
        }

        nonisolated init(_ audio: AudioTrack) {
            id = audio.id
            label = audio.label
            main = audio.main
        }
    }

    /// 覚えた名前 → 主音声 → 先頭の順で選ぶ (3.3)
    nonisolated static func pickAudioChoice(_ audios: [AudioChoice], savedName: String?) -> AudioChoice? {
        if let savedName, let match = audios.first(where: { $0.label == savedName }) {
            return match
        }
        if let main = audios.first(where: { $0.main == true }) {
            return main
        }
        return audios.first
    }

    /// `POST api/recordings/<id>/resume` の本文。`source` は観ているファイル
    /// (エンコード済みなら `encoded`、元の TS なら `ts`。3.3)
    struct ResumeBody: Encodable, Equatable, Sendable {
        var at: Double
        var length: Double
        var source: String

        nonisolated init(at: Double, length: Double, source: String) {
            self.at = at
            self.length = length
            self.source = source
        }
    }

    /// 物差し (`playback.axis`) から `resume` の `source` を決める (3.3)
    nonisolated static func resumeSource(axis: PlaybackAxis) -> String {
        axis == .encoded ? "encoded" : "ts"
    }

    nonisolated static func resumeBody(at: Double, duration: Double, axis: PlaybackAxis) -> ResumeBody {
        ResumeBody(at: max(0, at), length: max(0, duration), source: resumeSource(axis: axis))
    }

    /// 再生の速さの並び (3.5・iPhone-PlayerMenu)
    nonisolated static let speeds: [Double] = [1, 1.25, 1.5, 2]

    nonisolated static func speedName(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }

    // MARK: ピクチャ・イン・ピクチャ (#48)

    /// 窓に出す観られる範囲。`limit` はシークできる上限、`anchor` は開いているストリームの時刻が 0 になる位置。
    /// 録画の `stream` は PTS がそのまま位置なので anchor は 0、追っかけは開き直した位置
    nonisolated static func pictureInPictureTimeRange(limit: Double, anchor: Double) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: max(0, limit - anchor), preferredTimescale: 600))
    }

    /// 窓の再生の絵を「一時停止」にするか。止めているときだけにする。
    /// 読み込み中・繋ぎ直しは動き続けている扱い (そうしないと、窓で再生を押した直後に「一時停止」の絵になる)
    nonisolated static func pictureInPictureIsPaused(phase: RecordingSession.Phase) -> Bool {
        switch phase {
        case .paused, .ended, .stopped, .idle: true
        case .playing, .loading, .reconnecting: false
        }
    }

    /// PiP の窓が閉じたときに、裏の決まり (#32) を引き直して閉じるか
    nonisolated static func shouldCloseOnPictureInPictureEnd(inBackground: Bool, phase: RecordingSession.Phase) -> Bool {
        inBackground && shouldCloseOnBackground(phase: phase)
    }

    /// 映像の穴を、いまの位置から開き直して埋めるか (#32・#48)。
    /// 表にいるときと、裏でも PiP の窓に出ているとき。開き直しは穴 1 回につき 1 回だけにしてループさせない
    nonisolated static func shouldReopenForVideoGap(
        inBackground: Bool,
        pictureInPicture: Bool,
        alreadyReopened: Bool
    ) -> Bool {
        guard !alreadyReopened else { return false }
        return !inBackground || pictureInPicture
    }

    /// 録画・追っかけが裏に回ったとき接続を閉じるか (#32)。
    /// 再生中 (`phase == .playing`) は接続と音を保ち、一時停止中・読み込み中など再生していないときは閉じる。
    /// PiP の窓に出ている間は、止めていても窓を消さない (#48)
    nonisolated static func shouldCloseOnBackground(phase: RecordingSession.Phase, pictureInPicture: Bool = false) -> Bool {
        if pictureInPicture { return false }
        return phase != .playing
    }
}
