import Foundation
import Testing
@testable import Milu

@Suite struct VideoReplayTests {
    private func sample(pts: Int64, keyframe: Bool) -> FMP4Sample {
        FMP4Sample(
            trackID: 1,
            kind: .video,
            dts: pts,
            pts: pts,
            duration: 1,
            isKeyframe: keyframe,
            data: Data([0])
        )
    }

    @Test func waitsForFirstKeyframeAndPicksKeyframeBeforeNowEvenBeyondFiveSeconds() {
        var buffer: [FMP4Sample] = []
        let seconds: (FMP4Sample) -> Double? = { Double($0.pts) }

        // 裏に入った直後の非キーフレームは貯めない
        VideoReplay.append(sample(pts: 1, keyframe: false), to: &buffer, now: 1, seconds: seconds)
        #expect(buffer.isEmpty)
        #expect(VideoReplay.startIndex(in: buffer, now: 1, seconds: seconds) == nil)

        // キーフレームから貯め始め、5 秒以上離れていても now 以前の最後のキーフレームを選ぶ
        VideoReplay.append(sample(pts: 2, keyframe: true), to: &buffer, now: 1, seconds: seconds)
        VideoReplay.append(sample(pts: 5, keyframe: false), to: &buffer, now: 5, seconds: seconds)
        VideoReplay.append(sample(pts: 10, keyframe: false), to: &buffer, now: 10, seconds: seconds)
        VideoReplay.append(sample(pts: 15, keyframe: true), to: &buffer, now: 10, seconds: seconds)
        #expect(VideoReplay.startIndex(in: buffer, now: 12, seconds: seconds) == 0)
        #expect(buffer[0].pts == 2)

        // now が 15 を過ぎたら trim で前の GOP (pts=2..10) を捨てる
        VideoReplay.trim(&buffer, now: 16, seconds: seconds)
        #expect(buffer.map(\.pts) == [15])
        #expect(VideoReplay.startIndex(in: buffer, now: 16, seconds: seconds) == 0)
    }

    @Test func returnsNilWithoutKeyframesAndDropsOnSampleCap() {
        let seconds: (FMP4Sample) -> Double? = { Double($0.pts) }

        // キーフレームが 1 つも無ければ nil (次のキーフレーム待ち)
        let nonKeyframes = [sample(pts: 1, keyframe: false), sample(pts: 2, keyframe: false)]
        #expect(VideoReplay.startIndex(in: nonKeyframes, now: 5, seconds: seconds) == nil)

        // 先読み済みの録画で裏からすぐ戻ったときなど、now より後のキーフレームしか無ければ nil を返す
        let onlyFutureKeyframes = [sample(pts: 25, keyframe: true), sample(pts: 26, keyframe: false)]
        #expect(VideoReplay.startIndex(in: onlyFutureKeyframes, now: 10, seconds: seconds) == nil)
        #expect(VideoReplay.firstKeyframeIndex(in: onlyFutureKeyframes) == 0)

        // 上限を超えたとき、後ろにキーフレームがあればそこまで詰め、無ければ全部捨てる
        var withLaterKeyframe: [FMP4Sample] = []
        VideoReplay.append(sample(pts: 0, keyframe: true), to: &withLaterKeyframe, now: 10, maxSamples: 3, seconds: seconds)
        VideoReplay.append(sample(pts: 1, keyframe: false), to: &withLaterKeyframe, now: 10, maxSamples: 3, seconds: seconds)
        VideoReplay.append(sample(pts: 2, keyframe: false), to: &withLaterKeyframe, now: 10, maxSamples: 3, seconds: seconds)
        VideoReplay.append(sample(pts: 20, keyframe: true), to: &withLaterKeyframe, now: 10, maxSamples: 3, seconds: seconds)
        #expect(withLaterKeyframe.map(\.pts) == [20])

        var singleHugeGOP: [FMP4Sample] = []
        for pts: Int64 in 0...4 {
            VideoReplay.append(sample(pts: pts, keyframe: pts == 0), to: &singleHugeGOP, now: 10, maxSamples: 3, seconds: seconds)
        }
        #expect(singleHugeGOP.isEmpty)
    }

    @Test func allowsThreeRetriesAfterInitialFailure() {
        // 初回の失敗のあと 3 回までやり直し、4 回目の失敗で次のキーフレーム待ちに落とす
        #expect(VideoReplay.shouldRetryFailure(retryCount: 1))
        #expect(VideoReplay.shouldRetryFailure(retryCount: 2))
        #expect(VideoReplay.shouldRetryFailure(retryCount: 3))
        #expect(!VideoReplay.shouldRetryFailure(retryCount: 4))
    }
}
