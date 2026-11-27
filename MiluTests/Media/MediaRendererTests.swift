import AVFoundation
import Foundation
import Testing
@testable import Milu

private final class MediaRendererBundleToken {}

@Suite @MainActor struct MediaRendererTests {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: MediaRendererBundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "mp4"))
        return try Data(contentsOf: url)
    }

    private func parse(_ data: Data) throws -> ([FMP4Track], [FMP4Sample]) {
        var tracks: [FMP4Track] = []
        var samples: [FMP4Sample] = []
        for event in FMP4Demuxer().feed(data) {
            switch event {
            case .initialization(let value): tracks = value
            case .samples(let value): samples.append(contentsOf: value)
            }
        }
        return (tracks, samples)
    }

    /// 裏に回って映像の層を止めていても (`setVideoEnabled(false)`)、音だけで再生が始まり位置が進む
    @Test func advancesAudioWhileVideoDisabledAndRecoversVideoOnForeground() async throws {
        @MainActor final class Box {
            var latest = RendererState()
        }
        let data = try fixture("live-h264")
        let events = FMP4Demuxer().feed(data)

        let box = Box()
        let renderer = MediaRenderer(displayLayer: AVSampleBufferDisplayLayer()) { state in
            Task { @MainActor in box.latest = state }
        }
        defer { renderer.stop() }

        renderer.setVideoEnabled(false, epoch: 1)
        renderer.reset(live: true, from: 0, ruler: false, generation: 1)
        MediaQueue.media.async {
            for event in events {
                renderer.handle(event)
            }
        }

        // 1 秒ぶん受け取ると再生が始まり、映像の層に渡していなくても時刻が進む
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if box.latest.isPlaying, box.latest.position > 0.15 { break }
        }
        #expect(box.latest.isPlaying)
        #expect(box.latest.position > 0.05)
        #expect(box.latest.buffered > 0)
        #expect(!box.latest.videoFailed)

        // 表に戻して手元のキーフレームから映像を流し直しても失敗せず、位置が進み続ける
        let before = box.latest.position
        renderer.setVideoEnabled(true, epoch: 2)
        for _ in 0..<50 where box.latest.videoEpoch < 2 || box.latest.position <= before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(box.latest.videoEpoch == 2)
        #expect(box.latest.position > before)
        #expect(!box.latest.videoFailed)
    }

    /// 映像の標本の長さから、表示のモードに渡すコマ数と形式を出す (3.3)
    @Test func reportsVideoFrameRateAndFormat() async throws {
        @MainActor final class Box {
            var latest = RendererState()
        }
        let data = try fixture("live-h264")
        let events = FMP4Demuxer().feed(data)
        let (_, samples) = try parse(data)
        let videoTrack = try #require(events.compactMap { event -> [FMP4Track]? in
            if case .initialization(let tracks) = event { return tracks }
            return nil
        }.first?.first { $0.kind == .video })
        // 実装は最後に処理した映像の標本の長さからコマ数を出す
        let lastVideo = try #require(samples.last { $0.trackID == videoTrack.id })
        let expected = Double(videoTrack.timescale) / Double(lastVideo.duration)

        let box = Box()
        let renderer = MediaRenderer(displayLayer: AVSampleBufferDisplayLayer()) { state in
            Task { @MainActor in box.latest = state }
        }
        defer { renderer.stop() }

        renderer.reset(live: true, from: 0, ruler: false, generation: 1)
        MediaQueue.media.async {
            for event in events {
                renderer.handle(event)
            }
        }

        var tries = 0
        while box.latest.frameRate != expected, tries < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            tries += 1
        }
        let format = try #require(box.latest.format)
        // 音声の形式ではなく、映像 (H.264) の形式が載っていること
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        #expect(abs(box.latest.frameRate - expected) < 0.01, "frameRate=\(box.latest.frameRate) expected=\(expected)")
    }

    @Test func recordingEndStartsWithLessThanOneSecondAndReportsDrain() async throws {
        @MainActor final class Box {
            var states: [RendererState] = []
        }
        let (tracks, samples) = try parse(fixture("live-h264"))
        let video = try #require(tracks.first { $0.kind == .video })
        let videoSamples = samples.filter { $0.trackID == video.id }
        let first = try #require(videoSamples.first)
        let shortTail = Array(videoSamples.prefix {
            Double($0.pts + $0.duration - first.pts) / Double(video.timescale) < 0.75
        })
        try #require(first.isKeyframe)
        try #require(shortTail.count > 1)

        let box = Box()
        let renderer = MediaRenderer(displayLayer: AVSampleBufferDisplayLayer()) { state in
            Task { @MainActor in box.states.append(state) }
        }
        defer { renderer.stop() }

        renderer.reset(live: false, from: 0, ruler: true, generation: 1)
        MediaQueue.media.async {
            renderer.handle(.initialization([video]))
            renderer.handle(.samples(shortTail))
        }
        for _ in 0..<100 where !(box.states.contains { $0.buffered > 0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let beforeEOF = try #require(box.states.last)
        try #require(beforeEOF.buffered > 0 && beforeEOF.buffered < 1)
        #expect(!beforeEOF.isPlaying)
        #expect(!beforeEOF.recordingEndDrained)

        renderer.drainRecordingEnd(generation: 1)
        for _ in 0..<100 where !(box.states.contains { $0.recordingEndDrained }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = try #require(box.states.firstIndex { $0.isPlaying && !$0.recordingEndDrained })
        let drained = try #require(box.states.firstIndex { $0.recordingEndDrained })
        #expect(started < drained)
        #expect(box.states[drained].position > box.states[started].position)
        #expect(box.states[drained].buffered == 0)
        #expect(!box.states[drained].videoFailed)
    }

    /// 非ライブ再生中に控えが空のまま表へ戻ったとき、`videoGap` を即座に 1 回だけ知らせて `false` に戻す
    @Test func reportsVideoGapOnceWhenNonLiveHasNoPendingKeyframe() async throws {
        @MainActor final class Box {
            var states: [RendererState] = []
        }
        let data = try fixture("live-h264")
        let events = FMP4Demuxer().feed(data)

        let box = Box()
        let renderer = MediaRenderer(displayLayer: AVSampleBufferDisplayLayer()) { state in
            Task { @MainActor in box.states.append(state) }
        }
        defer { renderer.stop() }

        renderer.reset(live: false, from: 0, ruler: true, generation: 1)
        MediaQueue.media.async {
            for event in events {
                renderer.handle(event)
            }
        }

        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if box.states.last?.isPlaying == true { break }
        }
        #expect(box.states.last?.isPlaying == true)

        // 裏へ回してすぐ表へ戻す (その間に新しいキーフレームが届いていないので控えは空)
        renderer.setVideoEnabled(false, epoch: 1)
        renderer.setVideoEnabled(true, epoch: 2)
        for _ in 0..<50 where !(box.states.contains { $0.videoEpoch == 2 }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let epoch2States = box.states.filter { $0.videoEpoch == 2 }
        #expect(epoch2States.filter(\.videoGap).count == 1)

        // 同じ enabled の早期 return でも videoGap は false のまま報告される
        renderer.setVideoEnabled(true, epoch: 3)
        for _ in 0..<50 where !(box.states.contains { $0.videoEpoch == 3 }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let epoch3 = try #require(box.states.last { $0.videoEpoch == 3 })
        #expect(!epoch3.videoGap)
    }
}
