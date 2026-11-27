import UIKit

#if os(iOS)
/// iPhone の向き。ふだんは縦、ライブの全画面は横、録画は縦横を許し、自動横画面がオンなら再生開始で横を求める (3.5.3)。
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()
    static let autoLandscapeKey = "autoLandscapePlayback"

    private(set) var mask: UIInterfaceOrientationMask = .portrait
    private var requestGeneration = 0

    /// 「再生時に自動で横画面にする」が効くか。iPhone だけ (iPad・Mac では常にオフ)
    static func shouldAutoLandscape(
        defaults: UserDefaults = .standard,
        isPhone: Bool = DeviceName.isPhone
    ) -> Bool {
        isPhone && defaults.bool(forKey: autoLandscapeKey)
    }

    /// 録画の再生画面を開くとき。縦横どちらも許しつつ、自動横画面がオンなら最初から横を求める
    @discardableResult
    func openRecording(
        defaults: UserDefaults = .standard,
        isPhone: Bool = DeviceName.isPhone
    ) -> UIInterfaceOrientationMask? {
        let initial: UIInterfaceOrientationMask? = Self.shouldAutoLandscape(defaults: defaults, isPhone: isPhone)
            ? .landscape
            : nil
        lock(.all, preferred: initial, isPhone: isPhone)
        return initial
    }

    func lock(
        _ mask: UIInterfaceOrientationMask,
        preferred: UIInterfaceOrientationMask? = nil,
        isPhone: Bool = DeviceName.isPhone
    ) {
        self.mask = mask
        guard isPhone else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        notifyControllers(in: scene)
        applyGeometry(preferred ?? mask, in: scene)
    }

    /// いま許している向きはそのままで、その向きへ回す (録画の「全画面」)
    func request(_ mask: UIInterfaceOrientationMask, isPhone: Bool = DeviceName.isPhone) {
        guard isPhone else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }
        applyGeometry(mask, in: scene)
    }

    private func notifyControllers(in scene: UIWindowScene) {
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }

    private func applyGeometry(_ target: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        requestGeneration += 1
        let generation = requestGeneration
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target), errorHandler: Self.ignore)
        // fullScreenCover や sheet の出し入れの最中は要求が断られることがあるので、遷移完了後にも求める
        if let coordinator = topController(in: scene)?.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self, weak scene] _ in
                guard let self, let scene, self.requestGeneration == generation else { return }
                self.notifyControllers(in: scene)
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: target), errorHandler: Self.ignore)
            }
        }
    }

    private func topController(in scene: UIWindowScene) -> UIViewController? {
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    /// 失敗しても何もしない。この closure は main 以外の queue で呼ばれるので、
    /// MainActor の closure を渡すと隔離の検査で落ちる (App が裏にあるときの要求など)
    nonisolated private static func ignore(_ error: any Error) {}
}
#endif
