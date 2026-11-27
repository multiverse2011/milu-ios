import Foundation
import Testing
import UIKit
@testable import Milu

@Suite @MainActor struct OrientationLockTests {
    private func makeDefaults() -> UserDefaults {
        let name = "OrientationLockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func deviceIsPhoneExcludesPadAndMac() {
        #expect(DeviceName.isPhone(idiom: .phone))
        #expect(!DeviceName.isPhone(idiom: .pad))
        #expect(!DeviceName.isPhone(idiom: .mac))
        #expect(!DeviceName.isPhone(idiom: .tv))
        #expect(!DeviceName.isPhone(idiom: .phone, isiOSAppOnMac: true))
        #expect(!DeviceName.isPhone(idiom: .phone, isMacCatalystApp: true))
    }

    @Test func shouldAutoLandscapeDefaultsToOffAndRequiresPhone() {
        let defaults = makeDefaults()
        // 既定はオフ
        #expect(!OrientationLock.shouldAutoLandscape(defaults: defaults, isPhone: true))

        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        #expect(OrientationLock.shouldAutoLandscape(defaults: defaults, isPhone: true))
        // iPad・Mac ではオンでも効かない
        #expect(!OrientationLock.shouldAutoLandscape(defaults: defaults, isPhone: false))

        defaults.set(false, forKey: OrientationLock.autoLandscapeKey)
        #expect(!OrientationLock.shouldAutoLandscape(defaults: defaults, isPhone: true))
    }

    @Test func openRecordingAllowsPortraitReturnWhileRequestingLandscapeWhenOn() {
        let defaults = makeDefaults()
        let lock = OrientationLock()

        // オフなら最初から横には回さず、縦横とも許す
        #expect(lock.openRecording(defaults: defaults, isPhone: true) == nil)
        #expect(lock.mask == .all)

        // オンなら最初は横を求めるが、mask は .all のまま (「全画面をやめる」で縦に戻れる)
        defaults.set(true, forKey: OrientationLock.autoLandscapeKey)
        #expect(lock.openRecording(defaults: defaults, isPhone: true) == .landscape)
        #expect(lock.mask == .all)

        // 閉じたら縦固定に戻る
        lock.lock(.portrait, isPhone: true)
        #expect(lock.mask == .portrait)

        // iPad・Mac ではオンでも横を求めない
        #expect(lock.openRecording(defaults: defaults, isPhone: false) == nil)
    }
}
