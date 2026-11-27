import Foundation
import Testing

@testable import Milu

@Suite struct SettingsViewTests {
    @Test func urlsPointToAyushioHttpsPages() {
        #expect(AppLinks.privacyPolicy.absoluteString == "https://ayushio.com/privacy/milu/")
    }
}
