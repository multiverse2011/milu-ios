import Foundation
import MediaPlayer
import Testing
@testable import Milu

@MainActor
final class SpyNowPlayingBackend: NowPlayingBackend {
    var info: NowPlayingItem?
    var commandsEnabled = false
    var onPlay: (() -> Bool)?
    var onPause: (() -> Bool)?
    var onToggle: (() -> Bool)?

    func bind(
        onPlay: @escaping @MainActor () -> Bool,
        onPause: @escaping @MainActor () -> Bool,
        onToggle: @escaping @MainActor () -> Bool
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onToggle = onToggle
    }

    func setInfo(_ item: NowPlayingItem?) {
        info = item
    }

    func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
    }
}

@Suite @MainActor struct NowPlayingControllerTests {
    private func makeService(programTitle: String? = "ニュース7") -> Service {
        Service(
            id: 101,
            type: .GR,
            name: "NHK総合1・東京",
            remoteControlKey: 1,
            logo: nil,
            live: "/api/services/101/live",
            airing: true,
            video: true,
            now: programTitle.map {
                CurrentProgram(
                    id: 1,
                    title: $0,
                    startAt: 0,
                    endAt: 1_800_000,
                    reserved: false,
                    recording: false,
                    audios: []
                )
            }
        )
    }

    private func makeRecording() throws -> Recording {
        let json = """
        {"id":1,"title":"日曜劇場","name":"[字]日曜劇場","serviceId":10,"serviceName":"TBS1",
         "startAt":0,"endAt":3600000,"durationMs":3600000,"resumeMs":null,"watchedAt":null,
         "recording":false,"chase":null,"cmReliable":false,"poster":null,
         "files":[],"audio":"","audios":[]}
        """
        return try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
    }

    @Test func liveItemIncludesProgramTitleAndStation() {
        let playing = NowPlayingItem.live(service: makeService(), isPlaying: true)
        #expect(playing.title == "ニュース7")
        #expect(playing.station == "NHK総合1・東京")
        #expect(playing.isLive)
        #expect(playing.rate == 1)

        let dict = playing.dictionary()
        #expect(dict[MPMediaItemPropertyTitle] as? String == "ニュース7")
        #expect(dict[MPMediaItemPropertyArtist] as? String == "NHK総合1・東京")
        #expect(dict[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(dict[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)

        let paused = NowPlayingItem.live(service: makeService(), isPlaying: false)
        #expect(paused.dictionary()[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)

        // 番組情報が無ければ局名を題にし、同じ字を二重に出さない
        let noProgram = NowPlayingItem.live(service: makeService(programTitle: nil), isPlaying: true)
        #expect(noProgram.title == "NHK総合1・東京")
        #expect(noProgram.station == nil)
        #expect(noProgram.dictionary()[MPMediaItemPropertyArtist] == nil)
    }

    @Test func recordingItemIncludesProgramTitleStationAndProgress() throws {
        let item = NowPlayingItem.recording(
            recording: try makeRecording(),
            isPlaying: true,
            speed: 1.5,
            position: 120,
            duration: 3600
        )
        let dict = item.dictionary()
        #expect(dict[MPMediaItemPropertyTitle] as? String == "日曜劇場")
        #expect(dict[MPMediaItemPropertyArtist] as? String == "TBS1")
        #expect(dict[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(dict[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 120)
        #expect(dict[MPMediaItemPropertyPlaybackDuration] as? Double == 3600)
    }

    @Test func controllerRoutesCommandsAndGuardsOwnerOnClear() {
        let backend = SpyNowPlayingBackend()
        let controller = NowPlayingController(backend: backend)
        let first = UUID()
        let second = UUID()
        var played = 0
        var paused = 0
        var toggled = 0

        controller.update(
            owner: first,
            item: .live(service: makeService(), isPlaying: true),
            onPlay: { played += 1; return true },
            onPause: { paused += 1; return true },
            onToggle: { toggled += 1; return true }
        )
        #expect(backend.commandsEnabled)
        #expect(backend.info?.title == "ニュース7")
        #expect(backend.onPlay?() == true)
        #expect(backend.onPause?() == true)
        #expect(backend.onToggle?() == true)
        #expect(played == 1 && paused == 1 && toggled == 1)

        // 新しい再生が上書きしたあと、前の再生が遅れて close しても消さない
        controller.update(
            owner: second,
            item: .live(service: makeService(programTitle: "次の番組"), isPlaying: true),
            onPlay: { true },
            onPause: { true },
            onToggle: { true }
        )
        controller.clear(owner: first)
        #expect(backend.commandsEnabled)
        #expect(backend.info?.title == "次の番組")

        controller.clear(owner: second)
        #expect(!backend.commandsEnabled)
        #expect(backend.info == nil)
    }
}
