import SwiftUI
import Testing
import UIKit
@testable import Milu

@Suite struct FontTests {
    @Test func denpaFontIsRegistered() {
        #expect(UIFont(name: DenpaFont.postScriptName, size: 12) != nil)
    }

    /// 放送の字の .body の標準の大きさが、システム書体の .body と同じ。
    /// 既定でない文字サイズの環境でも落ちないよう、比べる trait を決めて渡す
    @Test func bodyBaseSizeMatchesSystemBody() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        #expect(DenpaFont.baseSize(of: .body, traits: traits)
            == UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize)
    }

    /// tvOS の UIFont に largeTitle は無いので、SwiftUI がその段に使う大きさに合わせる
    @Test func largeTitleBaseSizeMatchesSystemLargeTitle() {
        let context = EnvironmentValues().fontResolutionContext
        #expect(DenpaFont.baseSize(of: .largeTitle) == Font.largeTitle.resolve(in: context).pointSize)
    }
}
