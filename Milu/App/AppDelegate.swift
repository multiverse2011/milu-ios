import UIKit

/// iPhone はふだん縦で、再生画面の出入りと自動横画面の設定に合わせて OrientationLock の向きを返す (3.5.3)。iPad・Mac は固定しない。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        DeviceName.isPhone ? OrientationLock.shared.mask : .all
    }
}
