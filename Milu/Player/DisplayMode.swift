import CoreMedia
#if os(tvOS)
import AVFoundation
import AVKit
import UIKit
#endif

/// Apple TV の表示のモード (3.3)。映像の形式が決まったらテレビのモードを映像に合わせ、
/// 再生の画面を閉じたら元に戻す。録画・追っかけ (RecordingSession) とライブ (PlaybackSession) が
/// 同じ所を通る。tvOS だけ効く (`AVDisplayManager` は tvOS にしかない)。
@MainActor
enum DisplayMode {
    /// 映像の形式に合わせる。何度呼んでも同じ形式なら何もしない。
    /// テレビを掴めなかったときは「頼んだ」印を残さない (同じ形式で呼び直されたらまた試す)
    static func apply(format: CMFormatDescription?, frameRate: Double) {
        #if os(tvOS)
        guard let format, let manager = displayManager else { return }
        let rate = refreshRate(frameRate: frameRate)
        if let applied = applied, applied.rate == rate,
           CMFormatDescriptionEqual(applied.format, otherFormatDescription: format) {
            return
        }
        applied = (format, rate)
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: format)
        #endif
    }

    /// 再生の画面を閉じたら呼ぶ。テレビを元のモードに戻す
    static func reset() {
        #if os(tvOS)
        guard applied != nil else { return }
        applied = nil
        displayManager?.preferredDisplayCriteria = nil
        #endif
    }

    /// コマ数から、テレビに頼むリフレッシュレートを選ぶ (純粋)。近い標準の値へ寄せ、
    /// 分からないときは 60。テレビ (AVDisplayManager) は頼まれた値に一番近いモードを選ぶ。
    /// 標準より多いコマ数 (120 など) は、頼める中で一番近い 60 に寄せる。
    nonisolated static func refreshRate(frameRate: Double) -> Float {
        guard frameRate > 1 else { return 60 }
        let rate = Float(frameRate)
        let known: [Float] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
        return known.min { abs($0 - rate) < abs($1 - rate) } ?? 60
    }

    #if os(tvOS)
    /// 最後に頼んだ形式とレート。同じものを繰り返し頼まない
    private static var applied: (format: CMFormatDescription, rate: Float)?

    /// 画面のテレビのモードを司るもの
    private static var displayManager: AVDisplayManager? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .avDisplayManager
    }
    #endif
}
