import Foundation
import Testing
@testable import Milu

@Suite struct LivePlaybackPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    @Test func closedTwiceWithin30sWaits() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.closed, at: at(0)) == [.restartNow])
        #expect(policy.handle(.closed, at: at(1)) == [.restart(after: 1)])
        #expect(policy.handle(.closed, at: at(2)) == [.restart(after: 2)])
    }

    @Test func closedAfter30sRestartsNow() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.closed, at: at(0)) == [.restartNow])
        #expect(policy.handle(.closed, at: at(31)) == [.restartNow])
    }

    @Test func firstFrameResetsWait() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        _ = policy.handle(.closed, at: at(0))
        #expect(policy.handle(.closed, at: at(1)) == [.restart(after: 1)])
        #expect(policy.handle(.firstFrame, at: at(2)) == [.resetWait])
        #expect(policy.handle(.closed, at: at(3)) == [.restart(after: 1)])
    }

    @Test func failuresBackOffToOneTwoFourEightTen() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(0)) == [.restart(after: 1)])
        #expect(policy.handle(.failed(status: 500, message: nil, errorCode: nil), at: at(1)) == [.restart(after: 2)])
        #expect(policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(2)) == [.restart(after: 4)])
        #expect(policy.handle(.failed(status: 502, message: nil, errorCode: nil), at: at(3)) == [.restart(after: 8)])
        #expect(policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(4)) == [.restart(after: 10)])
        #expect(policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(5)) == [.restart(after: 10)])
    }

    @Test func busyStopsAfterThreeRetries() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        let busy = LiveEvent.failed(status: 503, message: "サーバが混んでいます", errorCode: nil)
        #expect(policy.handle(busy, at: at(0)) == [.restart(after: 1)])
        #expect(policy.handle(busy, at: at(1)) == [.restart(after: 2)])
        #expect(policy.handle(busy, at: at(2)) == [.restart(after: 4)])
        #expect(policy.handle(busy, at: at(3)) == [.stop(.serverBusy, retry: true)])
    }

    @Test func emptyStopsAfterThreeRetries() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.empty, at: at(0)) == [.restart(after: 1)])
        #expect(policy.handle(.empty, at: at(1)) == [.restart(after: 2)])
        #expect(policy.handle(.empty, at: at(2)) == [.restart(after: 4)])
        #expect(policy.handle(.empty, at: at(3)) == [.stop(.emptyStream, retry: true)])
    }

    @Test func refusedStopsWithMessage() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.failed(status: 404, message: "録画がありません", errorCode: nil), at: at(0))
            == [.stop(.refused("録画がありません"), retry: true)])
    }

    @Test func unsupportedFormatStopsWithoutRetry() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.failed(status: 406, message: nil, errorCode: nil), at: at(0))
            == [.stop(.noPlayableFormat, retry: false)])
    }

    @Test func unsupportedFormatWithEmptyPlayableStopsWithoutRetry() {
        var policy = LivePlaybackPolicy(playable: [])
        #expect(policy.handle(.failed(status: 406, message: nil, errorCode: nil), at: at(0))
            == [.stop(.noPlayableFormat, retry: false)])
    }

    @Test func responseResetsBusyCount() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        let busy = LiveEvent.failed(status: 503, message: "サーバが混んでいます", errorCode: nil)
        for _ in 0..<3 {
            _ = policy.handle(busy, at: at(0))
        }
        _ = policy.handle(.response, at: at(1))
        for _ in 0..<3 {
            let actions = policy.handle(busy, at: at(2))
            #expect(!actions.contains(.stop(.serverBusy, retry: true)))
        }
        #expect(policy.handle(busy, at: at(3)) == [.stop(.serverBusy, retry: true)])
    }

    @Test func firstFrameResetsYieldedCount() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        _ = policy.handle(.yielded, at: at(0))
        _ = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(1))
        _ = policy.handle(.firstFrame, at: at(2))
        for second in 3...5 {
            let actions = policy.handle(
                .failed(status: nil, message: nil, errorCode: nil),
                at: at(Double(second))
            )
            #expect(!actions.contains(.stop(.yielded, retry: true)))
        }
    }

    @Test func decodeFailureForUnusedCodecDoesNothing() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.decodeFailed(codec: .hevc), at: at(0)).isEmpty)
        #expect(policy.playable == [.h264])
    }

    @Test func decodeFailureRemovesTheCodec() {
        var policy = LivePlaybackPolicy(playable: [.h264, .hevc], currentCodec: .hevc)
        #expect(policy.handle(.decodeFailed(codec: .hevc), at: at(0)) == [.removeCodec(.hevc), .restartNow])
        #expect(policy.playable == [.h264])
    }

    @Test func decodeFailureWithNoPlayableStops() {
        var policy = LivePlaybackPolicy(playable: [.hevc], currentCodec: .hevc)
        #expect(policy.handle(.decodeFailed(codec: .hevc), at: at(0))
            == [.removeCodec(.hevc), .stop(.noPlayableFormat, retry: false)])
    }

    @Test func stallRetries() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.stalled, at: at(0)) == [.restart(after: 1)])
    }

    @Test func yieldedStopsAfterThreeFailures() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        #expect(policy.handle(.yielded, at: at(0)).isEmpty)
        _ = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(1))
        _ = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(2))
        let actions = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(3))
        #expect(actions.contains(.stop(.yielded, retry: true)))
    }

    @Test func yieldedExpiresAfter60s() {
        var policy = LivePlaybackPolicy(playable: [.h264])
        _ = policy.handle(.yielded, at: at(0))
        for second in 1...3 {
            _ = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(61 + Double(second)))
        }
        let actions = policy.handle(.failed(status: nil, message: nil, errorCode: nil), at: at(70))
        #expect(!actions.contains(.stop(.yielded, retry: true)))
    }
}
