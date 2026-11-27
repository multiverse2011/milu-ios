import SwiftUI

/// Apple TV の色。地はシステムの背景・material・`.quaternary` の階層、字は
/// `.primary` / `.secondary` の階層に任せる。ここには意味のある色だけを残す。
enum TVTheme {
    /// 映像の上に敷く膜の地 (TV-Live・TV-LiveDetail の帯)
    static let scrim = Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
    /// 白い QR の面に載せる字 (設定の白地に合わせる)
    static let qrInk = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255)
    /// 録画の赤 (録画中・予約の印)
    static let record = Color(red: 1, green: 0.27, blue: 0.23)
    // 設定の 3 画面を List にするまで残す (次のコミットで消す)
    static let fill = Color.white.opacity(0.07)
    static let muted = Color(white: 0.6)
    static let body = Color.white.opacity(0.86)
    /// 入力欄の地 (接続先の白い面)
    static let light = Color(red: 242 / 255, green: 244 / 255, blue: 248 / 255)
    /// 白い地に載せる字
    static let ink = Color(red: 11 / 255, green: 12 / 255, blue: 15 / 255)
}
