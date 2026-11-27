import Foundation
import UIKit

/// 画面の文言に出す端末の種類 (3.5)
@MainActor
enum DeviceName {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// iPhone だけ true (iPad・Mac は false)
    static var isPhone: Bool {
        isPhone(
            idiom: UIDevice.current.userInterfaceIdiom,
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            isMacCatalystApp: ProcessInfo.processInfo.isMacCatalystApp
        )
    }
    static var name: String { name(isPad: isPad, isTV: UIDevice.current.userInterfaceIdiom == .tv) }

    nonisolated static func name(isPad: Bool, locale: Locale = .current) -> String {
        isPad
            ? String(localized: LocalizedStringResource("iPad", locale: locale))
            : String(localized: LocalizedStringResource("iPhone", locale: locale))
    }

    /// Apple TV の画面に出す名前。tvOS は iPhone とも iPad とも書かない (D27)
    nonisolated static func name(isPad: Bool, isTV: Bool, locale: Locale = .current) -> String {
        isTV ? String(localized: LocalizedStringResource("Apple TV", locale: locale)) : name(isPad: isPad, locale: locale)
    }

    nonisolated static func isPhone(
        idiom: UIUserInterfaceIdiom,
        isiOSAppOnMac: Bool = false,
        isMacCatalystApp: Bool = false
    ) -> Bool {
        idiom == .phone && !isiOSAppOnMac && !isMacCatalystApp
    }
}
