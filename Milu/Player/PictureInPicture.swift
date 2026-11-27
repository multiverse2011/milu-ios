import AVFoundation

#if os(iOS)
import AVKit
import os

/// ピクチャ・イン・ピクチャ (PiP・#48)。ライブと録画で共通の制御をここにまとめ、
/// 違うのは `Source` の中身 (再生の操作と観られる範囲) だけにする。
/// `displayLayer` は `PlaybackSession`・`RecordingSession` が持っているものをそのまま使う。
/// AVKit の delegate は main で呼ぶ決まりなので、`@preconcurrency` のままで MainActor に載せている。
@MainActor
final class PictureInPicture: NSObject {
    /// 操作を任せる先 (ライブは `PlaybackSession`、録画は `RecordingSession`)
    @MainActor
    protocol Source: AnyObject {
        /// 止まっているか (窓の再生の絵。ライブの「止める」はストリームを止めること)
        var isPictureInPicturePaused: Bool { get }
        /// 観られる範囲。ライブは終わりが無いので無限
        var pictureInPictureTimeRange: CMTimeRange { get }
        func setPictureInPicturePlaying(_ playing: Bool)
        func skipPictureInPicture(by seconds: Double)
        /// 窓に入った・出た。裏にいる間の映像の止め方が変わる (#32)
        func pictureInPictureDidChange(_ active: Bool)
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    private var controller: AVPictureInPictureController?
    private weak var source: Source?
    /// 起動の最中か。`isPictureInPictureActive` は始まってからでないと true にならない
    private var starting = false
    /// 起動の最中に止めるよう言われた印。始まったところで閉じる (#48)
    private var stopsWhenStarted = false
    /// ライブか。スキップが無いので「止める」は遅らせず即時に渡す
    private let linear: Bool
    /// 最後に窓のスキップを受けた時刻から `skipSettle` 後。それまでの setPlaying(false) は無視する。
    /// 連続スキップでも最後の 1 件の期限だけが効く
    private var skipSettleDeadline: DispatchTime?
    /// 窓から来た「止める」。直後にスキップが来たら取り消す
    private var deferredPause: DispatchWorkItem?
    /// スキップの抑止中に捨てた「止める」があるか。窓が閉じたときだけ確定する (× で閉じると抑止中でも止める)。
    /// 「再生」が来たら消す。新しいスキップでは消さず、最後のスキップの抑止が明けたら消す
    private var suppressedPause = false
    /// スキップの約 2ms 前に「止める」が来る (シミュレーターでの観測値)。押した操作として遅れを感じない長さにする
    private static let pauseDeferral: TimeInterval = 0.15
    /// 起点はスキップのコールバックを受けた時刻 (シークの完了ではない)。
    /// 制約: この間に利用者が窓で押した一時停止も捨てる。AVKit が同じ setPlaying(false) で送るので、時間でしか見分けられない。
    /// 窓が閉じたときは捨てたものも確定するので、× で閉じれば止まる (代わりに、この間に「アプリに戻る」で閉じても止まる)
    private static let skipSettle: TimeInterval = 0.5
    /// 抑止期限の判定に使う今の時刻。テストで期限を過ぎた状態を作るためだけに差し替える
    var now: () -> DispatchTime = { .now() }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// `linear` はスキップのボタンを出さない (ライブはタイムシフトが無い・D17)
    init?(displayLayer: AVSampleBufferDisplayLayer, source: Source, linear: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.source = source
        self.linear = linear
        super.init()
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let created = AVPictureInPictureController(contentSource: contentSource)
        created.delegate = self
        // 再生中にホームへ戻ったら自動で小さい窓にする (#48)
        created.canStartPictureInPictureAutomaticallyFromInline = true
        created.requiresLinearPlayback = linear
        controller = created
    }

    func toggle() {
        if isActive {
            stop()
            return
        }
        // いま PiP を出せない (映像がまだ動いていないなど) ときは何もしない。
        // その場合は willStart も failedToStart も来ないので、起動中の印を立てたままにしない
        guard controller?.isPictureInPicturePossible == true else { return }
        // 利用者が押したときは、前の「止めるべき」の印を捨ててから始める
        stopsWhenStarted = false
        starting = true
        controller?.startPictureInPicture()
    }

    func stop() {
        if isActive {
            controller?.stopPictureInPicture()
            return
        }
        // 起動の最中は stop が効かないので、始まってから閉じる。始まっていないときは何もしない
        if starting {
            stopsWhenStarted = true
        }
    }

    /// 窓が閉じた・開けなかったとき、保留中の「止める」をその場で確定し、スキップの抑止も解く。
    /// × で閉じると「止める」のすぐあとに終了が来るので、#32 の切断判定より先に止めておく。
    /// スキップ直後の × は「止める」が抑止で捨てられるので、`suppressedPause` もここで確定する
    /// 期限が過ぎていれば、解除の予約がまだ走っていなくても、捨てた「止める」はスキップの最中のものとして確定しない
    private func settlePendingControls() {
        let pauses = deferredPause != nil || (suppressedPause && isSuppressingSkipPause)
        skipSettleDeadline = nil
        deferredPause?.cancel()
        deferredPause = nil
        suppressedPause = false
        if pauses {
            source?.setPictureInPicturePlaying(false)
        }
    }

    /// 最後のスキップの抑止期限の内か
    private var isSuppressingSkipPause: Bool {
        skipSettleDeadline.map { now() < $0 } ?? false
    }

    /// 再生と一時停止が変わったら、窓の絵を合わせ直す
    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }
}

extension PictureInPicture: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        source?.pictureInPictureTimeRange ?? .invalid
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        source?.isPictureInPicturePaused ?? true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        guard !linear else {
            source?.setPictureInPicturePlaying(playing)
            return
        }
        deferredPause?.cancel()
        deferredPause = nil
        if playing {
            suppressedPause = false
            source?.setPictureInPicturePlaying(true)
            return
        }
        // AVKit はスキップのボタンでも、スキップの直前と最中に setPlaying(false) を送ってくる。
        // 利用者は止めていないので、スキップの最中は無視し、直前のものはスキップが来たら取り消せるよう少し遅らせる
        if isSuppressingSkipPause {
            suppressedPause = true
            return
        }
        let pause = DispatchWorkItem { [weak self] in
            self?.deferredPause = nil
            self?.source?.setPictureInPicturePlaying(false)
        }
        deferredPause = pause
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseDeferral, execute: pause)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        deferredPause?.cancel()
        deferredPause = nil
        // 前の期限が切れていれば (解除の予約がまだでも)、そのとき捨てた「止める」は持ち越さない
        if !isSuppressingSkipPause {
            suppressedPause = false
        }
        let deadline = now() + Self.skipSettle
        skipSettleDeadline = deadline
        source?.skipPictureInPicture(by: skipInterval.seconds)
        // シークは開き直しなので、レイヤの時刻が新しい位置を指すのは少し後になる。
        // 開き直しの完了まで待つと窓が「探し中」のまま固まるので、1 回 runloop を回してから返す (#48)
        DispatchQueue.main.async { completionHandler() }
        // 最中の setPlaying(false) は返したあとにも少し遅れて来るので、間を置いてから受け付けに戻す
        // 後からスキップが来ていれば、その期限の予約に任せる
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, skipSettleDeadline == deadline else { return }
            skipSettleDeadline = nil
            suppressedPause = false
            controller?.invalidatePlaybackState()
        }
    }
}

extension PictureInPicture: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = true
        // 起動の最中に止めるよう言われていれば、その場で取り消す
        if stopsWhenStarted {
            pictureInPictureController.stopPictureInPicture()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = false
        // 起動の最中に止められた (選局・画面を閉じたなど)。自分の窓は開けずに閉じる
        guard !stopsWhenStarted else {
            stopsWhenStarted = false
            pictureInPictureController.stopPictureInPicture()
            return
        }
        source?.pictureInPictureDidChange(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = false
        stopsWhenStarted = false
        settlePendingControls()
        source?.pictureInPictureDidChange(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        Self.logger.error("pip failed to start: \(error.localizedDescription, privacy: .public)")
        starting = false
        stopsWhenStarted = false
        settlePendingControls()
        // 自動で始まらなかったときも、裏の映像の止め方を今の決まりに合わせ直す
        source?.pictureInPictureDidChange(false)
    }

    /// 元の再生の画面は閉じていない (画面を閉じるときは PiP も止める) ので、そのまま戻す
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
#else
/// tvOS に PiP は無い。ライブと録画のモデルを共有するため、同じ API の何もしない型を置く (D27)。
/// 作れないので `pictureInPicture` は常に nil になり、ボタンも出ない。
@MainActor
final class PictureInPicture: NSObject {
    @MainActor
    protocol Source: AnyObject {
        var isPictureInPicturePaused: Bool { get }
        var pictureInPictureTimeRange: CMTimeRange { get }
        func setPictureInPicturePlaying(_ playing: Bool)
        func skipPictureInPicture(by seconds: Double)
        func pictureInPictureDidChange(_ active: Bool)
    }

    var isActive: Bool { false }

    init?(displayLayer: AVSampleBufferDisplayLayer, source: Source, linear: Bool) {
        super.init()
        return nil
    }

    func toggle() {}
    func stop() {}
    func invalidatePlaybackState() {}
}
#endif
