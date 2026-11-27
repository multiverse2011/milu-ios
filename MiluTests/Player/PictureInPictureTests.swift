#if os(iOS)
import AVKit
import CoreMedia
import Testing
@testable import Milu

/// AVKit は窓のスキップでも、その直前と最中に setPlaying(false) を送ってくる (シミュレーターで確認)。
/// それで再生を止めず、利用者が押した一時停止だけを通すこと
/// PiP を使えないシミュレーター (iPhone など) では作れないので飛ばす
@MainActor
@Suite(.enabled(if: AVPictureInPictureController.isPictureInPictureSupported()))
struct PictureInPictureTests {
    private final class SpySource: PictureInPicture.Source {
        var isPictureInPicturePaused = false
        var pictureInPictureTimeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 60, preferredTimescale: 600))
        var playing: [Bool] = []
        var skips: [Double] = []
        /// 呼ばれた順 ("play"・"pause"・"skip"・"didChange(true/false)")
        var events: [String] = []
        func setPictureInPicturePlaying(_ playing: Bool) {
            self.playing.append(playing)
            events.append(playing ? "play" : "pause")
        }
        func skipPictureInPicture(by seconds: Double) {
            skips.append(seconds)
            events.append("skip")
        }
        func pictureInPictureDidChange(_ active: Bool) { events.append("didChange(\(active))") }
    }

    private func make(linear: Bool = false) throws -> (PictureInPicture, AVPictureInPictureController, SpySource) {
        let source = SpySource()
        let layer = AVSampleBufferDisplayLayer()
        let pip = try #require(PictureInPicture(displayLayer: layer, source: source, linear: linear))
        let controller = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: pip)
        )
        return (pip, controller, source)
    }

    private let tenSeconds = CMTime(seconds: 10, preferredTimescale: 1)

    @Test func pauseRightBeforeAndDuringSkipIsIgnored() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        try await Task.sleep(for: .milliseconds(800))
        #expect(source.skips == [10])
        #expect(source.playing.isEmpty)
    }

    @Test func pauseRightBeforeSkipAloneIsCancelled() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        try await Task.sleep(for: .milliseconds(800))
        #expect(source.playing.isEmpty)
    }

    /// 1 回目の解除が 2 回目の抑止を解かないこと
    @Test func consecutiveSkipsKeepSuppressingFromTheLastOne() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        try await Task.sleep(for: .milliseconds(400))
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        try await Task.sleep(for: .milliseconds(150))
        pip.pictureInPictureController(controller, setPlaying: false)
        try await Task.sleep(for: .seconds(1))
        #expect(source.skips == [10, 10])
        #expect(source.playing.isEmpty)
    }

    @Test func pauseFromWindowStillPauses() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, setPlaying: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(source.playing == [false])
        pip.pictureInPictureController(controller, setPlaying: true)
        #expect(source.playing == [false, true])
    }

    /// × で閉じると「止める」のすぐあとに終了が来る。止めてから閉じたと伝える (#32 の切断判定が .paused を見る)
    @Test func closingRightAfterPauseConfirmsPauseFirst() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        try await Task.sleep(for: .milliseconds(400))
        #expect(source.events == ["pause", "didChange(false)"])
    }

    /// スキップ直後に × で閉じると、AVKit の「止める」は抑止で捨てられる。閉じたときに止めてから伝える
    @Test func closingDuringSkipSuppressionConfirmsSuppressedPause() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        try await Task.sleep(for: .milliseconds(400))
        #expect(source.events == ["skip", "pause", "didChange(false)"])
    }

    /// 抑止で捨てた「止める」のあとに「再生」が来たら、閉じても止めない
    @Test func playAfterSuppressedPauseIsNotPausedOnClose() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.pictureInPictureController(controller, setPlaying: true)
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        try await Task.sleep(for: .milliseconds(400))
        #expect(source.events == ["skip", "play", "didChange(false)"])
    }

    /// スキップの最中に AVKit が送る「止める」は、抑止が明けたあとに閉じても止めない
    @Test func suppressedPauseExpiresWithSkipSuppression() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        try await Task.sleep(for: .milliseconds(800))
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        #expect(source.events == ["skip", "didChange(false)"])
    }

    /// 抑止期限を過ぎてから、解除の予約より先に閉じても、期限切れの「止める」は確定しない
    @Test func expiredSuppressedPauseIsNotConfirmedBeforeSettleRuns() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.now = { .now() + 1 }
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        #expect(source.events == ["skip", "didChange(false)"])
        // 作ってすぐ AVKit の窓を解放するとテストのプロセスが落ちるので、待機が終わるまで生かしておく
        try await Task.sleep(for: .milliseconds(400))
        withExtendedLifetime((pip, controller)) {}
    }

    /// 期限が切れたあと解除の予約より先に次のスキップが来ても、前の「止める」を持ち越さない
    @Test func expiredSuppressedPauseIsNotCarriedIntoNextSkip() async throws {
        let (pip, controller, source) = try make()
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureController(controller, setPlaying: false)
        pip.now = { .now() + 1 }
        pip.pictureInPictureController(controller, skipByInterval: tenSeconds) {}
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        #expect(source.events == ["skip", "skip", "didChange(false)"])
        try await Task.sleep(for: .milliseconds(400))
        withExtendedLifetime((pip, controller)) {}
    }

    @Test func livePausesImmediately() async throws {
        let (pip, controller, source) = try make(linear: true)
        pip.pictureInPictureController(controller, setPlaying: false)
        #expect(source.playing == [false])
        // 作ってすぐ AVKit の窓を解放するとテストのプロセスが落ちるので、待機が終わるまで pip と controller を生かしておく
        try await Task.sleep(for: .milliseconds(400))
        withExtendedLifetime((pip, controller)) {}
    }
}
#endif
