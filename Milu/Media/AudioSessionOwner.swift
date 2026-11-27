import AVFAudio
import Foundation

/// 音を出している再生の数。0 になったときだけ `AVAudioSession` を戻す。
/// ライブと録画が同時に生きていても、片方の `stop` でほかの音を止めない。
nonisolated final class AudioSessionOwner: @unchecked Sendable {
    static let shared = AudioSessionOwner()

    private let lock = NSLock()
    private var count = 0

    func activate() {
        lock.lock()
        count += 1
        lock.unlock()
        ensureActive()
    }

    /// カウントを増やさずに音の場を有効にし直す (一時停止からの再開など)
    func ensureActive() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    func release() {
        lock.lock()
        count = max(0, count - 1)
        let isLast = count == 0
        lock.unlock()
        guard isLast else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
