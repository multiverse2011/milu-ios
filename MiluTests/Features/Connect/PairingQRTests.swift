import Foundation
import Testing
@testable import Milu

@Suite struct PairingQRTests {
    /// ペアリングの QR は iPhone と Apple TV の両方が出す (4.2)
    @Test func imageForVerificationURL() throws {
        let url = try #require(URL(string: "http://denpa.lan:3000/device?code=WDJB-MJHT"))
        let image = try #require(PairingQR.image(for: url))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect(image.size.width == image.size.height)
    }
}
