import UIKit
import XCTest

@MainActor
private enum ScreenshotHarness {
    private struct Labels {
        let tryDemo: String
        let close: String
        let exitFullScreen: String
        let guideTab: String
        let liveTab: String
        let settingsTab: String
        let version: String
        let changeServer: String
        let exitDemo: String
        let programDescription: String
        let cast: String

        static func forLanguage(_ language: String) -> Labels {
            if language == "en" {
                return Labels(
                    tryDemo: "Try Demo",
                    close: "Close",
                    exitFullScreen: "Exit Full Screen",
                    guideTab: "Guide",
                    liveTab: "Live",
                    settingsTab: "Settings",
                    version: "Version",
                    changeServer: "Change Server",
                    exitDemo: "Exit Demo",
                    programDescription: "Description",
                    cast: "Cast"
                )
            }
            return Labels(
                tryDemo: "デモで試す",
                close: "閉じる",
                exitFullScreen: "全画面表示を終了",
                guideTab: "番組表",
                liveTab: "ライブ",
                settingsTab: "設定",
                version: "バージョン",
                changeServer: "接続先の変更",
                exitDemo: "デモを終了",
                programDescription: "番組内容",
                cast: "出演者"
            )
        }
    }

    static func run(in testCase: XCTestCase) {
        testCase.continueAfterFailure = false

        let language = ProcessInfo.processInfo.environment["MILU_SCREENSHOT_LANGUAGE"] ?? "ja"
        let labels = Labels.forLanguage(language)
        let localeArguments = language == "en"
            ? ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            : ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]

        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        testCase.addTeardownBlock {
            Task { @MainActor in
                XCUIDevice.shared.orientation = .portrait
            }
        }

        let app = XCUIApplication()
        // -autoLandscapePlayback NO は NSArgumentDomain 経由で @AppStorage を上書きする
        app.launchArguments = ["-MiluUITestDemo", "-autoLandscapePlayback", "NO"] + localeArguments
        app.launch()

        // 未接続の画面から始まったときは「デモで試す」を押す
        let tryDemoButton = app.buttons[labels.tryDemo]
        if tryDemoButton.exists {
            tryDemoButton.tap()
        }

        // 1. 録画
        let firstRecording = app.staticTexts["ドラマ「ひだまり荘の人々」 #8「屋上の約束」"].firstMatch
        XCTAssertTrue(firstRecording.waitForExistence(timeout: 10), "録画の一覧が表示されませんでした")
        pause(0.6)
        captureScreenshot(named: "01-recordings", in: testCase)

        // 2. 録画の再生
        firstRecording.tap()
        let closePlayerButton = app.buttons[labels.close]
        XCTAssertTrue(closePlayerButton.waitForExistence(timeout: 10), "録画の再生画面が開きませんでした")
        if isPad {
            // 横長の iPad は二段組 (映像 + 番組内容) にして撮る
            let exitFullscreen = app.buttons[labels.exitFullScreen]
            if exitFullscreen.waitForExistence(timeout: 3) {
                exitFullscreen.tap()
            }
        }
        XCTAssertTrue(app.staticTexts[labels.cast].waitForExistence(timeout: 5), "出演者が表示されませんでした")
        pause(1.2)
        if !closePlayerButton.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            _ = closePlayerButton.waitForExistence(timeout: 3)
        }
        captureScreenshot(named: "02-recording-player", in: testCase)

        closePlayerButton.tap()
        XCTAssertTrue(firstRecording.waitForExistence(timeout: 10), "録画の一覧に戻れませんでした")

        // 3. 番組表
        selectTab(labels.guideTab, in: app)
        XCTAssertTrue(
            app.staticTexts["ほしぞら放送"].firstMatch.waitForExistence(timeout: 10),
            "番組表が表示されませんでした"
        )
        pause(0.8)
        captureScreenshot(named: "03-guide", in: testCase)

        // 4. 番組の詳細
        openProgramSheet(in: app, programDescriptionLabel: labels.programDescription)
        XCTAssertTrue(
            app.staticTexts[labels.programDescription].firstMatch.waitForExistence(timeout: 5),
            "番組の詳細が表示されませんでした"
        )
        pause(0.5)
        captureScreenshot(named: "04-program-detail", in: testCase)
        dismissProgramSheet(in: app, isPad: isPad, closeLabel: labels.close)

        // 5. ライブ
        selectTab(labels.liveTab, in: app)
        XCTAssertTrue(
            app.staticTexts["あおばTV"].firstMatch.waitForExistence(timeout: 10),
            "ライブの局一覧が表示されませんでした"
        )
        pause(1.5)
        captureScreenshot(named: "05-live", in: testCase)

        // 6. 設定
        selectTab(labels.settingsTab, in: app)
        XCTAssertTrue(
            app.staticTexts[labels.version].firstMatch.waitForExistence(timeout: 10),
            "設定画面が表示されませんでした"
        )
        pause(0.5)
        captureScreenshot(named: "06-settings", in: testCase)

        // 設定からデモを終了し、接続画面の「デモで試す」からも入れることを確かめる
        let serverRow = app.staticTexts[labels.changeServer].firstMatch
        XCTAssertTrue(serverRow.waitForExistence(timeout: 5))
        serverRow.tap()
        let endDemoButton = app.buttons[labels.exitDemo]
        XCTAssertTrue(endDemoButton.waitForExistence(timeout: 5))
        endDemoButton.tap()
        XCTAssertTrue(tryDemoButton.waitForExistence(timeout: 5), "接続画面の「デモで試す」が表示されませんでした")
        tryDemoButton.tap()
        XCTAssertTrue(firstRecording.waitForExistence(timeout: 10), "「デモで試す」から録画一覧へ入れませんでした")
    }

    private static func selectTab(_ title: String, in app: XCUIApplication) {
        let tabBarButton = app.tabBars.buttons[title]
        if tabBarButton.waitForExistence(timeout: 5) {
            tabBarButton.tap()
            return
        }
        let fallback = app.buttons[title].firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "タブ「\(title)」が見つかりません")
        fallback.tap()
    }

    private static func openProgramSheet(in app: XCUIApplication, programDescriptionLabel: String) {
        let window = app.windows.firstMatch
        let candidates: [CGVector] = [
            CGVector(dx: 0.35, dy: 0.50),
            CGVector(dx: 0.35, dy: 0.58),
            CGVector(dx: 0.60, dy: 0.50),
        ]
        for offset in candidates {
            window.coordinate(withNormalizedOffset: offset).tap()
            if app.staticTexts[programDescriptionLabel].firstMatch.waitForExistence(timeout: 2) {
                return
            }
        }
    }

    private static func dismissProgramSheet(in app: XCUIApplication, isPad: Bool, closeLabel: String) {
        if isPad {
            let close = app.buttons[closeLabel]
            if close.waitForExistence(timeout: 3) {
                close.tap()
                pause(0.5)
                return
            }
        }
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.05, thenDragTo: end)
        pause(0.5)
    }

    private static func captureScreenshot(named name: String, in testCase: XCTestCase) {
        let screenshot = XCUIScreen.main.screenshot()
        let raw = screenshot.image
        let attachment: XCTAttachment
        if raw.imageOrientation == .up {
            attachment = XCTAttachment(screenshot: screenshot)
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = raw.scale
            format.opaque = true
            format.preferredRange = .standard
            let upright = UIGraphicsImageRenderer(size: raw.size, format: format).image { _ in
                raw.draw(in: CGRect(origin: .zero, size: raw.size))
            }
            attachment = XCTAttachment(image: upright)
        }
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private static func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

nonisolated final class AppStoreScreenshotsTests: XCTestCase {
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        ScreenshotHarness.run(in: self)
    }
}
