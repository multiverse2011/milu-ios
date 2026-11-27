import CoreMedia
import Foundation
import Testing
@testable import Milu

@Suite struct RecordingRulesTests {
    @Test func startsFromResume() {
        #expect(RecordingRules.startPosition(resumeMs: 754_000) == 754)
        #expect(RecordingRules.startPosition(resumeMs: nil) == 0)
        #expect(RecordingRules.startPosition(resumeMs: -1) == 0)
    }

    @Test func seekStaysInsideTheRecording() {
        #expect(RecordingRules.seek(100, by: -10, duration: 1790) == 90)
        #expect(RecordingRules.seek(3, by: -10, duration: 1790) == 0)
        #expect(RecordingRules.seek(1785, by: 10, duration: 1790) == 1790)
    }

    @Test func nextChapterSkipsTheCurrentOne() {
        let chapters = [
            Chapter(start: 0, end: 90, title: "オープニング"),
            Chapter(start: 90, end: 1710, title: "本編"),
            Chapter(start: 1710, end: 1800, title: "エンディング"),
        ]
        #expect(RecordingRules.nextChapter(chapters: chapters, position: 10) == 90)
        #expect(RecordingRules.nextChapter(chapters: chapters, position: 90.2) == 1710)
        // 最後のチャプターの中にいるときは次の頭が無い
        #expect(RecordingRules.nextChapter(chapters: chapters, position: 1750) == nil)
        #expect(RecordingRules.nextChapter(chapters: [], position: 10) == nil)
    }

    @Test func chapterTitleAtPosition() {
        let chapters = [
            Chapter(start: 0, end: 90, title: "オープニング"),
            Chapter(start: 90, end: 1710, title: "本編"),
        ]
        #expect(RecordingRules.chapterTitle(chapters: chapters, position: 0) == "オープニング")
        #expect(RecordingRules.chapterTitle(chapters: chapters, position: 100) == "本編")
        #expect(RecordingRules.chapterTitle(chapters: chapters, position: 1709.9) == "本編")
        // 最後の区間の end を過ぎても、直前のチャプターの題を出したままにする
        #expect(RecordingRules.chapterTitle(chapters: chapters, position: 1710) == "本編")
        #expect(RecordingRules.chapterTitle(chapters: chapters, position: 1790) == "本編")
        // 区間と区間の隙間でも、直前のチャプターの題
        let gapped = [
            Chapter(start: 0, end: 90, title: "オープニング"),
            Chapter(start: 100, end: 1710, title: "本編"),
        ]
        #expect(RecordingRules.chapterTitle(chapters: gapped, position: 95) == "オープニング")
        // 先頭のチャプターより前は題が無い
        #expect(RecordingRules.chapterTitle(chapters: gapped, position: -1) == nil)
        #expect(RecordingRules.chapterTitle(chapters: [], position: 10) == nil)
    }

    /// 一覧から開いた詳細でも、途中まで観た録画には「続きから再生」を出す (退行の再現)
    @Test func detailResumePosition() {
        #expect(RecordingRules.detailResumeMs(override: nil, saved: 754_000) == 754_000)
        #expect(RecordingRules.detailResumeMs(override: 200_000, saved: 754_000) == 200_000)
        // 観はじめ (1 秒未満) は「再生」に倒す
        #expect(RecordingRules.detailResumeMs(override: 0, saved: 754_000) == nil)
        #expect(RecordingRules.detailResumeMs(override: 800, saved: nil) == nil)
        #expect(RecordingRules.detailResumeMs(override: nil, saved: nil) == nil)
    }

    @Test func nextSpeedCycles() {
        #expect(RecordingRules.nextSpeed(after: 1) == 1.25)
        #expect(RecordingRules.nextSpeed(after: 1.25) == 1.5)
        #expect(RecordingRules.nextSpeed(after: 1.5) == 2)
        #expect(RecordingRules.nextSpeed(after: 2) == 1)
        // 並びに無い値からは先頭へ
        #expect(RecordingRules.nextSpeed(after: 3) == 1)
    }

    @Test func nextQualityItemCyclesThroughAutoAndCodecs() {
        let items = [
            PlaybackRules.QualityItem(codec: nil, title: "自動"),
            PlaybackRules.QualityItem(codec: .av1, title: "AV1"),
            PlaybackRules.QualityItem(codec: .hevc, title: "H.265"),
            PlaybackRules.QualityItem(codec: .h264, title: "H.264"),
        ]
        #expect(RecordingRules.nextQualityItem(items: items, selected: nil)?.codec == .av1)
        #expect(RecordingRules.nextQualityItem(items: items, selected: .av1)?.codec == .hevc)
        #expect(RecordingRules.nextQualityItem(items: items, selected: .hevc)?.codec == .h264)
        #expect(RecordingRules.nextQualityItem(items: items, selected: .h264)?.codec == nil)
        #expect(RecordingRules.nextQualityItem(items: [], selected: nil) == nil)
    }

    @Test func nextAudioCycles() {
        let tracks = [
            RecordingRules.AudioChoice(PlaybackAudio(id: "0", label: "主音声")),
            RecordingRules.AudioChoice(PlaybackAudio(id: "1", label: "副音声")),
        ]
        #expect(RecordingRules.nextAudioChoice(tracks: tracks, selected: tracks[0])?.id == "1")
        #expect(RecordingRules.nextAudioChoice(tracks: tracks, selected: tracks[1])?.id == "0")
        // まだ選ばれていなければ先頭
        #expect(RecordingRules.nextAudioChoice(tracks: tracks, selected: nil)?.id == "0")
        #expect(RecordingRules.nextAudioChoice(tracks: [], selected: nil) == nil)
    }

    @Test func finishedAtTheEnd() {
        #expect(RecordingRules.isFinished(position: 1790, duration: 1790))
        #expect(RecordingRules.isFinished(position: 1789.8, duration: 1790))
        #expect(!RecordingRules.isFinished(position: 1780, duration: 1790))
        #expect(!RecordingRules.isFinished(position: 10, duration: 0))
    }

    @Test func watchedFraction() {
        #expect(RecordingRules.watchedFraction(resumeMs: 754_000, durationMs: 1_790_000) == 754.0 / 1790)
        #expect(RecordingRules.watchedFraction(resumeMs: nil, durationMs: 1_790_000) == 0)
        #expect(RecordingRules.watchedFraction(resumeMs: 100, durationMs: nil) == 0)
    }

    @Test func picksSavedAudioThenFirst() {
        let audios = [
            PlaybackAudio(id: "0", label: "主音声"),
            PlaybackAudio(id: "1", label: "副音声"),
        ]
        #expect(RecordingRules.pickAudio(audios, savedName: "副音声")?.id == "1")
        #expect(RecordingRules.pickAudio(audios, savedName: "英語")?.id == "0")
        #expect(RecordingRules.pickAudio([], savedName: nil) == nil)
    }

    @Test func resumeBodyUsesTheAxisAsSource() {
        let body = RecordingRules.resumeBody(at: 12.5, duration: 100, axis: .encoded)
        #expect(body.at == 12.5)
        #expect(body.length == 100)
        #expect(body.source == "encoded")
        #expect(RecordingRules.resumeBody(at: 1, duration: 2, axis: .ts).source == "ts")
        let json = try! JSONEncoder().encode(body)
        let object = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(object["at"] as? Double == 12.5)
        #expect(object["length"] as? Double == 100)
        #expect(object["source"] as? String == "encoded")
    }

    @Test func chaseRecordedThroughAndLatest() {
        #expect(RecordingRules.recordedThrough(position: 100, buffered: 20, scheduled: 3600) == 120)
        #expect(RecordingRules.recordedThrough(position: 3590, buffered: 20, scheduled: 3600) == 3600)
        #expect(RecordingRules.recordedThrough(position: 100, buffered: 20, scheduled: 0) == 120)
        #expect(RecordingRules.latestPosition(recordedThrough: 120) == 117)
        #expect(RecordingRules.latestPosition(recordedThrough: 2) == 0)
        // 「最新」は進むだけ
        #expect(RecordingRules.latestTarget(position: 50, recordedThrough: 120) == 117)
        #expect(RecordingRules.latestTarget(position: 118, recordedThrough: 120) == 118)
    }

    @Test func elapsedThroughIsCappedByTheSchedule() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(600)
        #expect(RecordingRules.elapsedThrough(headMs: 1_000_000, now: now, scheduled: 3600) == 600)
        #expect(RecordingRules.elapsedThrough(headMs: 1_000_000, now: now, scheduled: 300) == 300)
        #expect(RecordingRules.elapsedThrough(headMs: 2_000_000, now: now, scheduled: 3600) == 0)
    }

    @Test func elapsedThroughUsesTheRecordingHeadNotTheProgramStart() {
        // 19:00 開始の番組を 19:05 から録った。20:00 に追っかけを開いた
        let programStartMs: Int64 = 1_000_000
        let headMs = programStartMs + 300_000
        let now = Date(timeIntervalSince1970: 1_000_000 / 1000 + 3600)
        // 番組の始まりから数えると 3600 秒。録画の先頭からなら 3300 秒
        #expect(RecordingRules.elapsedThrough(headMs: headMs, now: now, scheduled: 5400) == 3300)
        // jikkyo.head が無ければ見積もらない
        #expect(RecordingRules.elapsedThrough(headMs: nil, now: now, scheduled: 5400) == 0)
    }

    @Test func caughtUpAtTheRecordedEdge() {
        #expect(RecordingRules.caughtUp(position: 117, recordedThrough: 120))
        #expect(RecordingRules.caughtUp(position: 116, recordedThrough: 120) == false)
    }

    @Test func chaseFinishedNeedsADuration() {
        #expect(RecordingRules.chaseFinished(position: 715, durationMs: 720_000))
        #expect(RecordingRules.chaseFinished(position: 700, durationMs: 720_000) == false)
        #expect(RecordingRules.chaseFinished(position: 715, durationMs: nil) == false)
    }

    @Test func speedNames() {
        #expect(RecordingRules.speedName(1) == "1×")
        #expect(RecordingRules.speedName(1.25) == "1.25×")
        #expect(RecordingRules.speedName(2) == "2×")
    }

    @Test func shouldCloseOnBackgroundOnlyWhenNotPlaying() {
        #expect(RecordingRules.shouldCloseOnBackground(phase: .playing) == false)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .paused) == true)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .loading) == true)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .reconnecting) == true)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .idle) == true)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .ended) == true)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .stopped) == true)
    }

    @Test func shouldNotCloseOnBackgroundInPictureInPicture() {
        // PiP の窓に出ている間は、止めていても窓を消さない (#48)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .paused, pictureInPicture: true) == false)
        #expect(RecordingRules.shouldCloseOnBackground(phase: .playing, pictureInPicture: true) == false)
    }

    @Test func shouldCloseAfterPictureInPictureEnds() {
        // 窓を閉じた裏では #32 の決まりを引き直す
        #expect(RecordingRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .paused))
        #expect(RecordingRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .loading))
        #expect(RecordingRules.shouldCloseOnPictureInPictureEnd(inBackground: true, phase: .playing) == false)
        // 表にいるときは裏の決まりは関係ない
        #expect(RecordingRules.shouldCloseOnPictureInPictureEnd(inBackground: false, phase: .paused) == false)
    }

    @Test func pictureInPicturePlaybackState() {
        // 止めているときだけ「一時停止」の絵にする。読み込み中・繋ぎ直しは動き続けている扱い
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .paused))
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .ended))
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .stopped))
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .idle))
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .playing) == false)
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .loading) == false)
        #expect(RecordingRules.pictureInPictureIsPaused(phase: .reconnecting) == false)
    }

    @Test func pictureInPictureTimeRangeFollowsTheLayerClock() {
        // 録画の stream は PTS がそのまま位置。追っかけは開き直した位置から 0 で始まる
        let stream = RecordingRules.pictureInPictureTimeRange(limit: 600, anchor: 0)
        #expect(stream.start == .zero)
        #expect(stream.duration.seconds == 600)
        let chase = RecordingRules.pictureInPictureTimeRange(limit: 900, anchor: 600)
        #expect(chase.start == .zero)
        #expect(chase.duration.seconds == 300)
        // 開き直した位置より前には縮めない
        #expect(RecordingRules.pictureInPictureTimeRange(limit: 600, anchor: 900).duration.seconds == 0)
    }

    @Test func reopenForVideoGapOnlyOnceInPictureInPicture() {
        // 表にいるときは今のまま開き直す (#32)
        #expect(RecordingRules.shouldReopenForVideoGap(inBackground: false, pictureInPicture: false, alreadyReopened: false))
        // 裏でも窓に出ているなら開き直す (#48)
        #expect(RecordingRules.shouldReopenForVideoGap(inBackground: true, pictureInPicture: true, alreadyReopened: false))
        // 裏で窓が無いなら次のキーフレームを待つ
        #expect(RecordingRules.shouldReopenForVideoGap(inBackground: true, pictureInPicture: false, alreadyReopened: false) == false)
        // 穴 1 回につき開き直しは 1 回だけ
        #expect(RecordingRules.shouldReopenForVideoGap(inBackground: false, pictureInPicture: true, alreadyReopened: true) == false)
    }
}
