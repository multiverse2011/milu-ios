import Foundation
import Testing

@testable import Milu

struct CaptionSourceTests {
    private let base = URL(string: "http://127.0.0.1:3000")!

    private func items(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func passesVideoRungWhenPresent() {
        let url = CaptionSource.url(baseURL: base, serviceID: 101, codec: "h264", audioID: "0:main", rung: "2")
        #expect(url?.path == "/api/services/101/captions")
        #expect(items(url) == ["codec": "h264", "audio": "0:main", "rung": "2"])
    }

    @Test func omitsRungWhenVideoHasNone() {
        let url = CaptionSource.url(baseURL: base, serviceID: 101, codec: "h264", audioID: nil, rung: nil)
        #expect(items(url) == ["codec": "h264"])
    }
}
