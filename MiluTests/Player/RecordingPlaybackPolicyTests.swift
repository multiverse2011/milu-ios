import Foundation
import Testing
@testable import Milu

@Suite struct RecordingPlaybackPolicyTests {
    private func policy(_ playable: [OfferCodec] = [.h264]) -> RecordingPlaybackPolicy {
        RecordingPlaybackPolicy(playable: playable)
    }

    @Test func closedBeforeTheEndReopensAtTheSamePosition() {
        var policy = policy()
        let actions = policy.handle(.closed, position: 600, duration: 1790)
        #expect(actions == [.reopen(from: 600, after: 0)])
    }

    @Test func repeatedCloseAtTheSamePositionWaits() {
        var policy = policy()
        #expect(policy.handle(.closed, position: 1200, duration: 1790)
            == [.reopen(from: 1200, after: 0)])
        #expect(policy.handle(.closed, position: 1200, duration: 1790)
            == [.reopen(from: 1200, after: 1)])
        #expect(policy.handle(.closed, position: 1200, duration: 1790)
            == [.reopen(from: 1200, after: 2)])
        // 進んでから閉じたら、またすぐ開き直して待ちを戻す
        #expect(policy.handle(.closed, position: 1205, duration: 1790)
            == [.reopen(from: 1205, after: 0)])
        #expect(policy.handle(.closed, position: 1205, duration: 1790)
            == [.reopen(from: 1205, after: 1)])
    }

    @Test func firstFrameAtTheSamePositionKeepsTheRepeatedCloseWait() {
        var policy = policy()
        _ = policy.handle(.closed, position: 1200, duration: 1790)
        _ = policy.handle(.closed, position: 1200, duration: 1790)
        policy.firstFrame(at: 1200)
        #expect(policy.handle(.closed, position: 1200, duration: 1790)
            == [.reopen(from: 1200, after: 2)])
    }

    @Test func firstFrameAfterProgressResetsTheRepeatedCloseWait() {
        var policy = policy()
        _ = policy.handle(.closed, position: 1200, duration: 1790)
        _ = policy.handle(.closed, position: 1200, duration: 1790)
        policy.firstFrame(at: 1250)
        #expect(policy.handle(.closed, position: 1250, duration: 1790)
            == [.reopen(from: 1250, after: 0)])
    }

    @Test func closedAtTheEndFinishes() {
        var policy = policy()
        #expect(policy.handle(.closed, position: 1789.9, duration: 1790) == [.end])
    }

    @Test func closedInTheLastFiveSecondsFinishes() {
        var policy = policy()
        #expect(policy.handle(.closed, position: 1786, duration: 1790) == [.end])
        #expect(policy.handle(.closed, position: 1784, duration: 1790) == [.reopen(from: 1784, after: 0)])
    }

    @Test func failuresBackOffToOneTwoFourEightTen() {
        var policy = policy()
        let failure = RecordingEvent.failed(status: 500, message: nil, errorCode: nil)
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 1)])
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 2)])
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 4)])
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 8)])
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 10)])
        #expect(policy.handle(failure, position: 120, duration: 1790) == [.reopen(from: 120, after: 10)])
    }

    @Test func firstFrameResetsTheWait() {
        var policy = policy()
        let failure = RecordingEvent.failed(status: 500, message: nil, errorCode: nil)
        _ = policy.handle(failure, position: 100, duration: 1790)
        _ = policy.handle(failure, position: 100, duration: 1790)
        policy.firstFrame(at: 100)
        #expect(policy.handle(failure, position: 100, duration: 1790) == [.reopen(from: 100, after: 1)])
    }

    @Test func busyStopsAfterThreeRetries() {
        var policy = policy()
        let busy = RecordingEvent.failed(status: 503, message: "サーバが混んでいます", errorCode: nil)
        #expect(policy.handle(busy, position: 30, duration: 1790) == [.reopen(from: 30, after: 1)])
        #expect(policy.handle(busy, position: 30, duration: 1790) == [.reopen(from: 30, after: 2)])
        #expect(policy.handle(busy, position: 30, duration: 1790) == [.reopen(from: 30, after: 4)])
        #expect(policy.handle(busy, position: 30, duration: 1790) == [.stop(.serverBusy, retry: true)])
    }

    @Test func other503RetriesWithoutLimit() {
        var policy = policy()
        let failure = RecordingEvent.failed(status: 503, message: "入れ替え中", errorCode: nil)
        for expected in [1.0, 2, 4, 8, 10, 10, 10] {
            #expect(policy.handle(failure, position: 30, duration: 1790) == [.reopen(from: 30, after: expected)])
        }
    }

    @Test func emptyStopsAfterThreeRetries() {
        var policy = policy()
        #expect(policy.handle(.empty, position: 30, duration: 1790) == [.reopen(from: 30, after: 1)])
        #expect(policy.handle(.empty, position: 30, duration: 1790) == [.reopen(from: 30, after: 2)])
        #expect(policy.handle(.empty, position: 30, duration: 1790) == [.reopen(from: 30, after: 4)])
        #expect(policy.handle(.empty, position: 30, duration: 1790) == [.stop(.emptyStream, retry: true)])
    }

    @Test func refusedStopsWithMessage() {
        var policy = policy()
        let failure = RecordingEvent.failed(status: 404, message: "録画がありません", errorCode: nil)
        #expect(policy.handle(failure, position: 30, duration: 1790) == [.stop(.refused("録画がありません"), retry: false)])
    }

    @Test func unsupportedStops() {
        var policy = policy()
        let failure = RecordingEvent.failed(status: 406, message: nil, errorCode: nil)
        #expect(policy.handle(failure, position: 30, duration: 1790) == [.stop(.noPlayableFormat, retry: false)])
    }

    @Test func decodeFailureRemovesTheCodecAndReopens() {
        var policy = policy([.h264, .hevc])
        #expect(policy.handle(.decodeFailed(codec: .hevc), position: 120, duration: 1790)
            == [.removeCodec(.hevc), .reopen(from: 120, after: 0)])
        #expect(policy.playable == [.h264])
    }

    @Test func decodeFailureWithNoPlayableStops() {
        var policy = policy([.hevc])
        #expect(policy.handle(.decodeFailed(codec: .hevc), position: 120, duration: 1790)
            == [.removeCodec(.hevc), .stop(.noPlayableFormat, retry: false)])
    }

    @Test func stalledReopensFromThePosition() {
        var policy = policy()
        #expect(policy.handle(.stalled, position: 400, duration: 1790) == [.reopen(from: 400, after: 1)])
    }
}
