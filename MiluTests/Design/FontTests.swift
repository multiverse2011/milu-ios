import Testing
import UIKit
@testable import Milu

@Suite struct FontTests {
    @Test func denpaFontIsRegistered() {
        #expect(UIFont(name: DenpaFont.postScriptName, size: 12) != nil)
    }
}
