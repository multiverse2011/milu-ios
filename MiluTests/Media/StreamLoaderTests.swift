import Foundation
import Testing
@testable import Milu

private final class BundleToken {}

@Suite struct StreamLoaderTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "live-h264", withExtension: "mp4"))
        return try Data(contentsOf: url)
    }

    /// URLSession の delegate を直に呼んで、200 の応答のあとに `data` が届いたところを作る
    private func deliver(_ data: Data, to loader: StreamLoader) {
        let url = URL(string: "http://127.0.0.1:9/api/services/1/live")!
        let task = URLSession.shared.dataTask(with: url)
        MediaQueue.media.sync {
            loader.urlSession(
                URLSession.shared,
                dataTask: task,
                didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                completionHandler: { _ in }
            )
            loader.urlSession(URLSession.shared, dataTask: task, didReceive: data)
        }
    }

    @Test func dropsDataDeliveredAfterCancel() throws {
        let data = try fixture()
        let events = Box(0)
        let loader = StreamLoader(url: URL(string: "http://127.0.0.1:9/live")!, mode: .live, pace: { 0 })
        loader.onInitialization = { _ in events.value += 1 }
        loader.onSamples = { _ in events.value += 1 }
        loader.cancel()
        // cancel のあとに、もう列に積まれていた delegate のコールバックが走る
        deliver(data, to: loader)
        #expect(events.value == 0)
    }
}

extension StreamLoaderTests {
    @Test func holdingLoaderDeliversOnlyAfterRelease() throws {
        let data = try fixture()
        let events = Box<[String]>([])
        let loader = StreamLoader(url: URL(string: "http://127.0.0.1:9/live")!, mode: .live, holding: true, pace: { 0 })
        loader.onInitialization = { _ in events.value.append("init") }
        loader.onSamples = { _ in events.value.append("samples") }
        deliver(data, to: loader)
        #expect(events.value.isEmpty)
        loader.release()
        MediaQueue.media.sync {}
        #expect(events.value.first == "init")
        #expect(events.value.contains("samples"))
        loader.cancel()
    }

    @Test func holdingLoaderReportsReadyOnceWithHeaders() throws {
        let data = try fixture()
        let ready = Box<[String?]>([])
        let loader = StreamLoader(url: URL(string: "http://127.0.0.1:9/live")!, mode: .live, holding: true, pace: { 0 })
        loader.onReady = { codec, rung in ready.value.append("\(codec ?? "-") \(rung ?? "-")") }
        injectResponse(into: loader, codec: "h264", rung: "2")
        #expect(ready.value.isEmpty)
        injectData(data, into: loader)
        injectData(data, into: loader)
        #expect(ready.value == ["h264 2"])
        loader.cancel()
    }

    @Test func holdingLoaderWaitsForVideoSampleBeforeReady() {
        let ready = Box(0)
        let loader = StreamLoader(url: URL(string: "http://127.0.0.1:9/live")!, mode: .live, holding: true, pace: { 0 })
        loader.onReady = { _, _ in ready.value += 1 }
        injectResponse(into: loader)
        func sample(_ kind: FMP4Track.Kind) -> FMP4Sample {
            FMP4Sample(trackID: kind == .video ? 1 : 2, kind: kind, dts: 0, pts: 0, duration: 1, isKeyframe: true, data: Data([0]))
        }
        MediaQueue.media.sync {
            loader.deliver(.initialization([]))
            // 音声だけの塊が先に来ても、まだ採用しない
            loader.deliver(.samples([sample(.audio)]))
        }
        #expect(ready.value == 0)
        MediaQueue.media.sync { loader.deliver(.samples([sample(.audio), sample(.video)])) }
        #expect(ready.value == 1)
        loader.cancel()
    }

    /// 一時停止していて今のレンダラの溜まりが上限 (30 秒) を超えていても、試しの接続は止めずに ready まで進む
    @Test func holdingBufferedLoaderIsNotSuspendedByCurrentRendererBuffer() async throws {
        let server = try OneShotHTTPServer(headers: ["Content-Type": "video/mp4", "X-Content-Type-Options": "nosniff", "X-Denpa-Codec": "h264", "X-Denpa-Rung": "2"], body: try fixture(), bodyDelay: 1.2)
        defer { server.stop() }
        #expect(server.port != 0)
        let ready = Box<String?>(nil)
        let loader = StreamLoader(url: server.url, mode: .buffered, holding: true, pace: { 40 })
        loader.onReady = { codec, _ in ready.value = codec ?? "-" }
        loader.start()
        for _ in 0..<160 where ready.value == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ready.value == "h264")
        loader.cancel()
    }
}
