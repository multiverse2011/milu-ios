import Testing
import UIKit
@testable import Milu

@Suite struct FontTests {
    @Test func denpaFontIsRegistered() {
        #expect(UIFont(name: DenpaFont.postScriptName, size: 12) != nil)
    }

    /// 放送の字の .body の標準の大きさが、システム書体の .body と同じ
    @Test func bodyBaseSizeMatchesSystemBody() {
        #expect(DenpaFont.baseSize(of: .body) == UIFont.preferredFont(forTextStyle: .body).pointSize)
    }
}
