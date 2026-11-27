import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Milu

@Suite struct RootViewTests {
    private func findController<T: UIViewController>(ofType type: T.Type, in controller: UIViewController) -> T? {
        if let matched = controller as? T {
            return matched
        }
        for child in controller.children {
            if let found = findController(ofType: type, in: child) {
                return found
            }
        }
        return nil
    }

    private func findController<T: UIViewController>(ofType type: T.Type, in view: UIView) -> T? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let matched = current as? T {
                return matched
            }
            responder = current.next
        }
        for subview in view.subviews {
            if let found = findController(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }

    private func locateNavigationController(from root: UIViewController) -> UINavigationController? {
        findController(ofType: UINavigationController.self, in: root)
            ?? findController(ofType: UINavigationController.self, in: root.view)
    }

    private func locateTabBarController(from root: UIViewController) -> UITabBarController? {
        findController(ofType: UITabBarController.self, in: root)
            ?? findController(ofType: UITabBarController.self, in: root.view)
    }

    private func pump(_ duration: Duration = .milliseconds(150)) async {
        try? await Task.sleep(for: duration)
    }

    @Test func pairViewPushesInNavigationStackAndPopCancelsPairing() async throws {
        let codeCalls = Box(0)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                codeCalls.value += 1
                return reply(
                    request, 200,
                    #"{"deviceCode":"d-\#(codeCalls.value)","userCode":"WDJB-MJHT","verificationUri":"device","verificationUriComplete":"device?code=WDJB-MJHT","expiresIn":600,"interval":600}"#
                )
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let suiteName = "RootViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            service: service,
            keychain: StubTokenStore(),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hosting = UIHostingController(rootView: RootView().environment(model))
        window.rootViewController = hosting
        window.isHidden = false
        hosting.view.layoutIfNeeded()
        defer {
            model.cancelPairing()
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suiteName)
        }

        for _ in 0..<20 where locateNavigationController(from: hosting) == nil {
            await pump(.milliseconds(50))
        }
        let nav = try #require(locateNavigationController(from: hosting))
        #expect(nav.viewControllers.count == 1)

        // 接続先を入れて進む → PairView が同じ NavigationStack に push される
        model.address = "http://127.0.0.1:3000"
        await model.connectField()
        for _ in 0..<40 where nav.viewControllers.count < 2 {
            await pump(.milliseconds(50))
        }
        #expect(locateNavigationController(from: hosting) === nav)
        #expect(nav.viewControllers.count == 2)
        #expect(nav.topViewController?.navigationItem.hidesBackButton == false)
        #expect(nav.interactivePopGestureRecognizer?.isEnabled == true)

        // pop で戻ったとき model.cancelPairing() が呼ばれ、ペアリング状態が残らない
        _ = nav.popViewController(animated: false)
        hosting.view.layoutIfNeeded()
        for _ in 0..<40 where model.pairing != nil {
            await pump(.milliseconds(50))
        }
        #expect(nav.viewControllers.count == 1)
        #expect(model.pairing == nil)
        #expect(model.server == nil)

        // もう一度進めること
        await model.connectField()
        for _ in 0..<40 where nav.viewControllers.count < 2 {
            await pump(.milliseconds(50))
        }
        #expect(nav.viewControllers.count == 2)
        #expect(model.pairing != nil)
        #expect(codeCalls.value == 2)
    }

    @Test func pairingSuccessTransitionsRootViewToMainTab() async throws {
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"WDJB-MJHT","verificationUri":"device","verificationUriComplete":"device?code=WDJB-MJHT","expiresIn":600,"interval":1}"#
                )
            }
            if request.url?.path.hasSuffix("api/device/token") == true {
                return reply(request, 200, #"{"token":"denpa_ok","tokenType":"Bearer"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return reply(request, 200, "[]")
            }
            return reply(request, 401, #"{"error":"unauthorized"}"#)
        }
        var service = ConnectionService(transport: transport)
        service.retryDelay = .zero
        service.sleep = { _ in }
        let suiteName = "RootViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            service: service,
            keychain: StubTokenStore(),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hosting = UIHostingController(rootView: RootView().environment(model))
        window.rootViewController = hosting
        window.isHidden = false
        hosting.view.layoutIfNeeded()
        defer {
            model.cancelPairing()
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suiteName)
        }

        for _ in 0..<20 where locateNavigationController(from: hosting) == nil {
            await pump(.milliseconds(50))
        }
        let connectNav = try #require(locateNavigationController(from: hosting))

        model.address = "http://127.0.0.1:3000"
        await model.connectField()
        for _ in 0..<40 where connectNav.viewControllers.count < 2 {
            await pump(.milliseconds(50))
        }
        #expect(connectNav.viewControllers.count == 2)

        for _ in 0..<60 where model.server == nil {
            await pump(.milliseconds(50))
        }
        hosting.view.layoutIfNeeded()
        for _ in 0..<40 where connectNav.view.window != nil {
            await pump(.milliseconds(50))
        }

        #expect(model.server?.token == "denpa_ok")
        #expect(model.pairing == nil)
        #expect(model.phase == .connected)
        #expect(connectNav.view.window == nil)
    }

    @Test func rePairingWhileConnectedShowsPairViewAtRootInsteadOfMainTab() async throws {
        let url = URL(string: "http://127.0.0.1:3000")!
        let failAuth = Box(false)
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("api/device/code") == true {
                return reply(
                    request, 200,
                    #"{"deviceCode":"d","userCode":"WDJB-MJHT","verificationUri":"device","verificationUriComplete":"device?code=WDJB-MJHT","expiresIn":600,"interval":600}"#
                )
            }
            if failAuth.value {
                if request.value(forHTTPHeaderField: "Authorization") != nil {
                    return reply(request, 401, #"{"error":"invalid_token"}"#)
                }
                return reply(request, 401, #"{"error":"unauthorized"}"#)
            }
            return reply(request, 200, "[]")
        }
        let suiteName = "RootViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(url.absoluteString, forKey: "serverURL")
        let model = AppModel(
            service: ConnectionService(transport: transport),
            keychain: StubTokenStore([url: "old"]),
            defaults: defaults,
            startsEvents: false,
            transport: transport
        )

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hosting = UIHostingController(rootView: RootView().environment(model))
        window.rootViewController = hosting
        window.isHidden = false
        hosting.view.layoutIfNeeded()
        defer {
            model.cancelPairing()
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suiteName)
        }

        for _ in 0..<40 where locateTabBarController(from: hosting) == nil {
            await pump(.milliseconds(50))
        }
        let tabBar = try #require(locateTabBarController(from: hosting))
        #expect(tabBar.view.window != nil)

        // 接続済みの状態で 401 により pairing が立ったら、MainTabView ではなく PairView がルートに出る
        failAuth.value = true
        _ = try? await model.get("api/services")
        #expect(model.server != nil)
        #expect(model.pairing != nil)

        hosting.view.layoutIfNeeded()
        for _ in 0..<40 where tabBar.view.window != nil || locateNavigationController(from: hosting) == nil {
            await pump(.milliseconds(50))
        }

        #expect(tabBar.view.window == nil)
        #expect(locateTabBarController(from: hosting) == nil)
        let pairNav = try #require(locateNavigationController(from: hosting))
        #expect(pairNav.view.window != nil)
        #expect(pairNav.viewControllers.count == 1)
    }
}
