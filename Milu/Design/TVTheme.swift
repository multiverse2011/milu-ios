import SwiftUI

/// Apple TV の色。地はシステムの背景・material・`.quaternary` の階層、字は
/// `.primary` / `.secondary` の階層に任せる。ここには意味のある色だけを残す。
enum TVTheme {
    /// 映像の上に敷く膜の地 (TV-Live・TV-LiveDetail の帯)
    static let scrim = Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
    /// 白い QR の面に載せる字
    static let qrInk = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255)
    /// 録画の赤 (録画中・予約の印)
    static let record = Color(red: 1, green: 0.27, blue: 0.23)
}
