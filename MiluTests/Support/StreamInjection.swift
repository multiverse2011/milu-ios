import Foundation
import Testing
@testable import Milu

private final class FixtureBundleToken {}

/// テスト用の fMP4 (`MiluTests/Fixtures`)
nonisolated func streamFixture(_ name: String = "live-h264") throws -> Data {
    let url = try #require(Bundle(for: FixtureBundleToken.self).url(forResource: name, withExtension: "mp4"))
    return try Data(contentsOf: url)
}

/// URLSession の delegate を直に呼んで、繋がずに 200 の応答を受けたところを作る
nonisolated func injectResponse(into loader: StreamLoader, codec: String? = "h264", rung: String? = nil) {
    var headers: [String: String] = [:]
    if let codec { headers["X-Denpa-Codec"] = codec }
    if let rung { headers["X-Denpa-Rung"] = rung }
    let response = HTTPURLResponse(url: loader.url, statusCode: 200, httpVersion: nil, headerFields: headers)!
    MediaQueue.media.sync {
        loader.urlSession(
            URLSession.shared,
            dataTask: URLSession.shared.dataTask(with: loader.url),
            didReceive: response,
            completionHandler: { _ in }
        )
    }
}

/// 200 のあとに中身が届いたところを作る
nonisolated func injectData(_ data: Data, into loader: StreamLoader) {
    MediaQueue.media.sync {
        loader.urlSession(URLSession.shared, dataTask: URLSession.shared.dataTask(with: loader.url), didReceive: data)
    }
}

/// 条件が揃うまで待つ。待ちきれなかったら、その場で失敗にする
@MainActor
func waitUntil(
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    // 回数ではなく時計で待つ。CI はカバレッジの計測で遅くなるので、余裕を持たせる
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    if !condition() {
        Issue.record("待ちきれなかった", sourceLocation: sourceLocation)
    }
}

/// 捨てられるはずのコールバックを処理し終えるまで待つ (MainActor の Task が走る間)
@MainActor
func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}
