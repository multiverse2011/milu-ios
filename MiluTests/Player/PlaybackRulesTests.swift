import CoreMedia
import Foundation
import Testing

@testable import Milu

/// 3.3 の決まりの単体テスト (8 節)。
struct PlaybackRulesTests {
    // MARK: P の組み立て

    @Test func playableSet() {
        // h264 は必ず入り、raw (MPEG-2) は入れない (D8)
        #expect(PlaybackRules.playable(hevcSupported: false, av1Supported: false) == [.h264])
        #expect(PlaybackRules.playable(hevcSupported: true, av1Supported: false) == [.h264, .hevc])
        #expect(PlaybackRules.playable(hevcSupported: false, av1Supported: true) == [.h264, .av1])
        #expect(PlaybackRules.playable(hevcSupported: true, av1Supported: true) == [.h264, .hevc, .av1])
    }

    // MARK: 録画の offers の選び方 (D7)

    private func offer(codec: OfferCodec, way: OfferWay, source: String? = nil) -> Offer {
        Offer(codec: codec, way: way, source: source, codecs: nil)
    }

    @Test func offerRule1PrefersPassthrough() {
        // rec1 の実際の形: file av1 + stream h264 + stream av1
        let offers = [
            offer(codec: .av1, way: .file, source: "encoded"),
            offer(codec: .h264, way: .stream),
            offer(codec: .av1, way: .stream),
        ]
        // 全部再生できるなら詰め替えの av1 (AV1 → H.265 → H.264)
        let all = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264, .hevc, .av1])
        #expect(all?.codec == .av1 && all?.way == .stream)
        // av1 が再生できない端末では変換の h264
        let h264Only = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264])
        #expect(h264Only?.codec == .h264)
    }

    @Test func offerRule1MultipleFilesPickAv1() {
        let offers = [
            offer(codec: .hevc, way: .file, source: "hevc"),
            offer(codec: .av1, way: .file, source: "encoded"),
            offer(codec: .h264, way: .stream),
            offer(codec: .hevc, way: .stream),
            offer(codec: .av1, way: .stream),
        ]
        let chosen = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264, .hevc, .av1])
        #expect(chosen?.codec == .av1)
    }

    @Test func offerRule2BroadcastHevc() {
        // 4K の局の録画: 応答の一番外の broadcast が hevc のとき、その hevc の詰め替え
        let offers = [
            offer(codec: .hevc, way: .stream),
            offer(codec: .h264, way: .stream),
        ]
        let chosen = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264, .hevc], broadcast: "hevc")
        #expect(chosen?.codec == .hevc)
        // hevc が再生できない端末では h264 (変換)
        let h264Only = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264], broadcast: "hevc")
        #expect(h264Only?.codec == .h264)
        // broadcast が無い (MPEG-2 の録画) ではルール 2 に入らない
        let noBroadcast = PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264, .hevc])
        #expect(noBroadcast?.codec == .h264)
    }

    @Test func offerRule4NothingPlayable() {
        // 元の TS だけの録画で P に mpeg2 が無い
        let offers = [offer(codec: .mpeg2, way: .raw)]
        #expect(PlaybackRules.selectRecordingOffer(offers: offers, playable: [.h264, .hevc, .av1]) == nil)
        // playable が空でも nil
        #expect(PlaybackRules.selectRecordingOffer(offers: offers, playable: []) == nil)
    }

    // MARK: 画質のメニュー

    @Test func recordingQualityMenu() {
        let offers = [
            offer(codec: .av1, way: .file, source: "encoded"),
            offer(codec: .h264, way: .stream),
            offer(codec: .av1, way: .stream),
        ]
        // AV1 → H.265 → H.264 の順に全部。hevc の stream が無いので入らない
        #expect(PlaybackRules.recordingQualityMenu(offers: offers, playable: [.h264, .hevc, .av1]) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .av1, title: "AV1"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
        // playable に無いものは出さない
        #expect(PlaybackRules.recordingQualityMenu(offers: offers, playable: [.h264]) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
        // 英語
        let en = Locale(identifier: "en_US")
        #expect(PlaybackRules.recordingQualityMenu(offers: offers, playable: [.h264], locale: en) == [
            PlaybackRules.QualityItem(codec: nil, title: "Auto"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
        #expect(PlaybackRules.codecName(.audio, locale: en) == "Audio")
    }

    @Test func liveQualityMenuPicksFirstPlayable() {
        // liveCodecs の先頭から playable にある最初の 1 つ
        #expect(PlaybackRules.liveQualityMenu(liveCodecs: [.hevc, .h264], playable: [.h264]) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
        #expect(PlaybackRules.liveQualityMenu(liveCodecs: [.hevc, .h264], playable: [.h264, .hevc]) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .hevc, title: "H.265"),
        ])
        // 追っかけでは H.265 を外して選ぶ
        #expect(PlaybackRules.liveQualityMenu(liveCodecs: [.hevc, .h264], playable: [.h264, .hevc], chase: true) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
        // 再生できるものが無ければ「自動」だけ
        #expect(PlaybackRules.liveQualityMenu(liveCodecs: [.av1], playable: [.h264]) == [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
        ])
        // 英語
        let en = Locale(identifier: "en_US")
        #expect(PlaybackRules.liveQualityMenu(liveCodecs: [.hevc, .h264], playable: [.h264], locale: en) == [
            PlaybackRules.QualityItem(codec: nil, title: "Auto"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ])
    }

    @Test func resolveQualityWithSavedValue() {
        let menu = PlaybackRules.liveQualityMenu(liveCodecs: [.hevc, .h264], playable: [.h264])
        // 覚えたものがメニューに無ければ「自動」 (nil)。値は消さない
        #expect(PlaybackRules.resolveQuality(saved: .hevc, menu: menu) == nil)
        #expect(PlaybackRules.resolveQuality(saved: .h264, menu: menu) == .h264)
        #expect(PlaybackRules.resolveQuality(saved: nil, menu: menu) == nil)
    }

    // MARK: 音声の選び方

    private func track(id: String, label: String, main: Bool? = nil) -> AudioTrack {
        AudioTrack(id: id, stream: 0, side: "both", label: label, main: main)
    }

    @Test func pickAudio() {
        let tracks = [
            track(id: "0:both", label: "ステレオ (日本語)", main: true),
            track(id: "1:both", label: "解説ステレオ"),
        ]
        // 覚えた名前があればそれ
        #expect(PlaybackRules.pickAudio(tracks: tracks, savedName: "解説ステレオ")?.id == "1:both")
        // 無ければ main
        #expect(PlaybackRules.pickAudio(tracks: tracks, savedName: "無い名前")?.id == "0:both")
        #expect(PlaybackRules.pickAudio(tracks: tracks, savedName: nil)?.id == "0:both")
        // main が無ければ先頭
        let noMain = [track(id: "0:both", label: "音声 1"), track(id: "1:both", label: "音声 2")]
        #expect(PlaybackRules.pickAudio(tracks: noMain, savedName: nil)?.id == "0:both")
        // 選べる音声が無ければ nil
        #expect(PlaybackRules.pickAudio(tracks: [], savedName: nil) == nil)
    }

    // MARK: 繋ぎ直しの待ち

    @Test func reconnectWaitDoublesUpToTenSeconds() {
        var timer = PlaybackRules.ReconnectTimer()
        // 1 秒から倍々で、上限は 10 秒
        #expect(timer.advance() == 1)
        #expect(timer.advance() == 2)
        #expect(timer.advance() == 4)
        #expect(timer.advance() == 8)
        #expect(timer.advance() == 10)
        #expect(timer.advance() == 10)
        // 最初のコマが映ったら 1 秒に戻る
        timer.reset()
        #expect(timer.advance() == 1)
    }

    // MARK: CM 飛ばしの行き先

    private let chapters = [
        Chapter(start: 0, end: 612.4, title: "本編"),
        Chapter(start: 612.4, end: 702.4, title: "CM"),
        Chapter(start: 702.4, end: 1790.5, title: "本編"),
    ]

    @Test func cmSkipDestination() {
        #expect(PlaybackRules.cmSkipDestination(chapters: chapters, position: 650) == 702.4)
        // CM の区間のはじまりちょうどでは飛ばす
        #expect(PlaybackRules.cmSkipDestination(chapters: chapters, position: 612.4) == 702.4)
        // 終わりちょうどでは飛ばさない
        #expect(PlaybackRules.cmSkipDestination(chapters: chapters, position: 702.4) == nil)
        // 本編では飛ばさない
        #expect(PlaybackRules.cmSkipDestination(chapters: chapters, position: 100) == nil)
        // CM が無い録画では飛ばさない
        #expect(PlaybackRules.cmSkipDestination(chapters: [Chapter(start: 0, end: 100, title: "本編")], position: 50) == nil)
    }

    // MARK: 裏に回ったときの判断 (#32)

    @Test func shouldCloseLiveOnBackgroundOnlyWhenNotPlaying() {
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .playing) == false)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: nil) == true)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .idle) == true)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .loading) == true)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .reconnecting) == true)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .paused) == true)
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .stopped) == true)
    }

    @Test func liveLifecycleAction() {
        // 再生中に裏へ回ったら接続と音を保つ
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .background, started: true, sessionPhase: .playing
        ) == .keepInBackground)

        // 再生していないとき (読み込み中・一時停止中・停止中) に裏へ回ったら閉じる
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .background, started: true, sessionPhase: .loading
        ) == .stop)
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .background, started: true, sessionPhase: .paused
        ) == .stop)
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .background, started: true, sessionPhase: .stopped
        ) == .stop)

        // タブを離れたら、再生中でも閉じる
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: false, appPhase: .active, started: true, sessionPhase: .playing
        ) == .stop)
        // タブを離れている間に裏・表を行き来しても開かない (a901338)
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: false, appPhase: .active, started: false, sessionPhase: nil
        ) == .none)

        // Control Center (.inactive) では止めない
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .inactive, started: true, sessionPhase: .playing
        ) == .none)
    }

    // MARK: ピクチャ・イン・ピクチャ (#48)

    @Test func backgroundKeepsVideoOnlyInPictureInPicture() {
        // 裏では音だけにする。PiP の窓に出ている間だけ映像も流す
        #expect(PlaybackRules.videoEnabled(inBackground: true, pictureInPicture: false) == false)
        #expect(PlaybackRules.videoEnabled(inBackground: true, pictureInPicture: true) == true)
        // 表にいる間は PiP に関わらず映像を流す
        #expect(PlaybackRules.videoEnabled(inBackground: false, pictureInPicture: false) == true)
        #expect(PlaybackRules.videoEnabled(inBackground: false, pictureInPicture: true) == true)
    }

    @Test func pictureInPicturePlaybackState() {
        // ライブは止めているときだけ「一時停止」の絵にする。読み込み中・繋ぎ直しは動き続けている扱い
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .paused))
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .stopped))
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .idle))
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .playing) == false)
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .loading) == false)
        #expect(PlaybackRules.pictureInPictureIsPaused(phase: .reconnecting) == false)
    }

    @Test func livePictureInPictureTimeRangeIsEndlessFromZero() {
        // 終わりが無い。始まりは 0 (負の無限を入れると start + duration が NaN になり得る)
        let range = PlaybackRules.livePictureInPictureTimeRange
        #expect(range.start == .zero)
        #expect(range.duration == .positiveInfinity)
    }

    @Test func shouldCloseAfterPictureInPictureEnds() {
        // 窓を閉じた裏では #32 の決まりを引き直す
        #expect(PlaybackRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .loading))
        #expect(PlaybackRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .reconnecting))
        #expect(PlaybackRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .paused))
        #expect(PlaybackRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .playing) == false)
        // 表にいるときは裏の決まりは関係ない
        #expect(PlaybackRules.shouldCloseOnPictureInPictureEnd(inBackground: false, phase: .paused) == false)
    }

    @Test func liveLifecycleKeepsTheWindowOpen() {
        // 窓を出している間は、止めていても裏で接続を閉じない
        #expect(PlaybackRules.shouldCloseLiveOnBackground(phase: .paused, pictureInPicture: true) == false)
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: true, appPhase: .background, started: true, sessionPhase: .paused, pictureInPicture: true
        ) == .keepInBackground)
        // タブを離れたら窓も閉じる (今のまま)
        #expect(PlaybackRules.liveLifecycleAction(
            isSelected: false, appPhase: .background, started: true, sessionPhase: .playing, pictureInPicture: true
        ) == .stop)
    }

    // MARK: 解像度 (段)

    @Test func rungMenuListsOriginalAndThreeHeights() {
        let ja = Locale(identifier: "ja_JP")
        let items = PlaybackRules.rungMenu(currentCodec: .h264, locale: ja)
        #expect(items.map(\.rung) == [0, 1, 2, 3])
        #expect(items.map(\.title) == ["元のまま", "720p", "540p", "360p"])
        // 形式がまだ分からないときも出す
        #expect(PlaybackRules.rungMenu(currentCodec: nil).count == 4)
    }

    @Test func rungMenuHiddenForAudioOnly() {
        #expect(PlaybackRules.rungMenu(currentCodec: .audio).isEmpty)
    }

    @Test func rungQueryItemsOmitRungZero() {
        #expect(PlaybackRules.rungQueryItems(0).isEmpty)
        #expect(PlaybackRules.rungQueryItems(2) == [URLQueryItem(name: "rung", value: "2")])
    }

    @Test func resolveRungDropsUnknownValues() {
        #expect(PlaybackRules.resolveRung(0) == 0)
        #expect(PlaybackRules.resolveRung(3) == 3)
        #expect(PlaybackRules.resolveRung(4) == 0)
        #expect(PlaybackRules.resolveRung(-1) == 0)
    }
}
