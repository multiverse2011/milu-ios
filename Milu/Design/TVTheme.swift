import SwiftUI

/// Apple TV の色。TV-* の絵は #15171d を地にし、入力欄と白いボタンは #f2f4f8。
enum TVTheme {
    static let background = Color(red: 21 / 255, green: 23 / 255, blue: 29 / 255)
    static let fill = Color.white.opacity(0.07)
    static let muted = Color(white: 0.6)
    /// 入力欄の地
    static let light = Color(red: 242 / 255, green: 244 / 255, blue: 248 / 255)
    /// 白い地に載せる字
    static let ink = Color(red: 11 / 255, green: 12 / 255, blue: 15 / 255)
    /// QR の下に敷く字
    static let qrInk = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255)
    /// 地に載せる本文
    static let body = Color.white.opacity(0.86)
    /// 映像の上に敷く膜の地 (TV-Live・TV-LiveDetail の帯)
    static let scrim = Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
    /// 録画の赤 (画面案 `--rec`)
    static let record = Color(red: 1, green: 0.27, blue: 0.23)
}
