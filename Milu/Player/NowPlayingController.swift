import Foundation
import MediaPlayer

/// ロック画面・コントロールセンターへ出す再生情報 (#32)。
nonisolated struct NowPlayingItem: Equatable, Sendable {
    var title: String
    var station: String?
    var isLive: Bool
    var isPlaying: Bool
    var rate: Double
    var position: Double?
    var duration: Double?

    nonisolated static func live(service: Service, isPlaying: Bool) -> NowPlayingItem {
        if let programTitle = service.now?.title, !programTitle.isEmpty {
            return NowPlayingItem(
                title: programTitle,
                station: service.name.isEmpty ? nil : service.name,
                isLive: true,
                isPlaying: isPlaying,
                rate: isPlaying ? 1 : 0,
                position: nil,
                duration: nil
            )
        }
        return NowPlayingItem(
            title: service.name,
            station: nil,
            isLive: true,
            isPlaying: isPlaying,
            rate: isPlaying ? 1 : 0,
            position: nil,
            duration: nil
        )
    }

    nonisolated static func recording(
        recording: Recording,
        isPlaying: Bool,
        speed: Double,
        position: Double,
        duration: Double
    ) -> NowPlayingItem {
        NowPlayingItem(
            title: recording.title,
            station: recording.serviceName.isEmpty ? nil : recording.serviceName,
            isLive: false,
            isPlaying: isPlaying,
            rate: isPlaying ? speed : 0,
            position: max(0, position),
            duration: duration > 0 ? duration : nil
        )
    }

    nonisolated func dictionary() -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let station, !station.isEmpty {
            info[MPMediaItemPropertyArtist] = station
        }
        if !isLive {
            if let position {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            }
            if let duration, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
        }
        return info
    }
}

@MainActor
protocol NowPlayingBackend: AnyObject {
    func bind(
        onPlay: @escaping @MainActor () -> Bool,
        onPause: @escaping @MainActor () -> Bool,
        onToggle: @escaping @MainActor () -> Bool
    )
    func setInfo(_ item: NowPlayingItem?)
    func setCommandsEnabled(_ enabled: Bool)
}

@MainActor
final class SystemNowPlayingBackend: NowPlayingBackend {
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?

    func bind(
        onPlay: @escaping @MainActor () -> Bool,
        onPause: @escaping @MainActor () -> Bool,
        onToggle: @escaping @MainActor () -> Bool
    ) {
        let center = MPRemoteCommandCenter.shared()
        if let playTarget { center.playCommand.removeTarget(playTarget) }
        if let pauseTarget { center.pauseCommand.removeTarget(pauseTarget) }
        if let toggleTarget { center.togglePlayPauseCommand.removeTarget(toggleTarget) }

        // 再生・一時停止だけ効かせ、シークや前後送りは出さない (#32)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        center.stopCommand.isEnabled = false

        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false

        playTarget = Self.addHandler(to: center.playCommand, perform: onPlay)
        pauseTarget = Self.addHandler(to: center.pauseCommand, perform: onPause)
        toggleTarget = Self.addHandler(to: center.togglePlayPauseCommand, perform: onToggle)
    }

    func setInfo(_ item: NowPlayingItem?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = item?.dictionary()
    }

    func setCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
    }

    /// `MPRemoteCommand.addTarget` の closure は `@MainActor` 指定を持たないので、
    /// `nonisolated` で受けて隔離の検査による SIGTRAP を防ぐ。
    nonisolated private static func addHandler(
        to command: MPRemoteCommand,
        perform: @escaping @MainActor () -> Bool
    ) -> Any {
        command.addTarget { _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    perform() ? .success : .noActionableNowPlayingItem
                }
            }
            Task { @MainActor in _ = perform() }
            return .success
        }
    }
}

/// いま開いている再生セッション 1 つだけを `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` に繋ぐ (#32)。
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private let backend: any NowPlayingBackend
    private(set) var currentOwner: UUID?
    private(set) var currentItem: NowPlayingItem?
    private var onPlay: (() -> Bool)?
    private var onPause: (() -> Bool)?
    private var onToggle: (() -> Bool)?

    init(backend: any NowPlayingBackend = SystemNowPlayingBackend()) {
        self.backend = backend
        backend.bind(
            onPlay: { [weak self] in self?.handlePlay() ?? false },
            onPause: { [weak self] in self?.handlePause() ?? false },
            onToggle: { [weak self] in self?.handleTogglePlayPause() ?? false }
        )
    }

    func update(
        owner: UUID,
        item: NowPlayingItem,
        onPlay: @escaping () -> Bool,
        onPause: @escaping () -> Bool,
        onToggle: @escaping () -> Bool
    ) {
        currentOwner = owner
        currentItem = item
        self.onPlay = onPlay
        self.onPause = onPause
        self.onToggle = onToggle
        backend.setCommandsEnabled(true)
        backend.setInfo(item)
    }

    func clear(owner: UUID) {
        guard currentOwner == owner else { return }
        currentOwner = nil
        currentItem = nil
        onPlay = nil
        onPause = nil
        onToggle = nil
        backend.setCommandsEnabled(false)
        backend.setInfo(nil)
    }

    @discardableResult
    func handlePlay() -> Bool {
        onPlay?() ?? false
    }

    @discardableResult
    func handlePause() -> Bool {
        onPause?() ?? false
    }

    @discardableResult
    func handleTogglePlayPause() -> Bool {
        onToggle?() ?? false
    }
}
