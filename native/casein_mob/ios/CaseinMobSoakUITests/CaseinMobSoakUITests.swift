import XCTest

final class CaseinMobSoakUITests: XCTestCase {
    private let bundleIdentifier = "com.alexandrefamilyfarm.casein-mob"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testColdLaunchPortraitAndAccessibility() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let startedAt = Date()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        addTiming("cold-foreground", since: startedAt)
        try requireCaseinAccessibility()
        XCTAssertTrue(app.staticTexts["Attention Inbox"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["https://casein.devbox.milcgroup.com"].waitForExistence(timeout: 15)
        )
        XCTAssertTrue(authoritativeLiveText().waitForExistence(timeout: 30))
        addTiming("cold-authoritative-live", since: startedAt)
    }

    func testWarmBackgroundForegroundAndLandscapeCanvas() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let resumedAt = Date()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        addTiming("warm-resume", since: resumedAt)
        try requireCaseinAccessibility()
        XCTAssertTrue(authoritativeLiveText().waitForExistence(timeout: 15))
        assertWindowFillsScreen(named: "warm-portrait")
        assertActionCenterSpansScreen()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape())
        assertWindowFillsScreen(named: "landscape-left")
        assertActionCenterSpansScreen()

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(waitForLandscape())
        assertWindowFillsScreen(named: "landscape-right")
        assertActionCenterSpansScreen()
    }

    func testSafeActionCenterTabsAndScroll() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try requireCaseinAccessibility()

        for label in ["Needs Me", "Live", "Failed", "Done"] {
            let tab = app.buttons[label]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.tap()
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertTrue(app.staticTexts["Attention Inbox"].exists)
    }

    func testKeyboardAndEvidenceHandoffWhenAuthoritativeInterventionExists() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        try requireCaseinAccessibility()

        let input = app.textFields.firstMatch.exists
            ? app.textFields.firstMatch
            : app.textViews.firstMatch

        guard input.exists else {
            throw XCTSkip(
                "No authoritative intervention card is available; keyboard/PWA proof remains blocked"
            )
        }

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(
            app.buttons["Open full terminal in PWA"].waitForExistence(timeout: 5),
            "authoritative intervention lacks its exact PWA escalation"
        )
    }

    private func requireCaseinAccessibility(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard app.staticTexts["Attention Inbox"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Casein Action Center is not exposed to XCUITest", file: file, line: line)
        }
    }

    private func authoritativeLiveText() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " · Live")).firstMatch
    }

    private func waitForLandscape() -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let frame = app.windows.firstMatch.frame
            if frame.width > frame.height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func assertWindowFillsScreen(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = app.windows.firstMatch.frame
        let screenSize = XCUIScreen.main.screenshot().image.size
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertEqual(frame.origin.x, 0, accuracy: 2, file: file, line: line)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 2, file: file, line: line)
        XCTAssertEqual(frame.width, screenSize.width, accuracy: 2, file: file, line: line)
        XCTAssertEqual(frame.height, screenSize.height, accuracy: 2, file: file, line: line)
        addText(
            name: "\(name)-geometry",
            value: "x=\(frame.origin.x) y=\(frame.origin.y) width=\(frame.width) height=\(frame.height)"
        )
    }

    private func assertActionCenterSpansScreen(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        let needsMe = app.buttons["Needs Me"]
        let done = app.buttons["Done"]
        XCTAssertTrue(needsMe.exists, file: file, line: line)
        XCTAssertTrue(done.exists, file: file, line: line)
        XCTAssertLessThanOrEqual(needsMe.frame.minX - window.frame.minX, 24, file: file, line: line)
        XCTAssertLessThanOrEqual(window.frame.maxX - done.frame.maxX, 24, file: file, line: line)
    }

    private func addTiming(_ name: String, since start: Date) {
        addText(name: name, value: String(format: "%.3f seconds", Date().timeIntervalSince(start)))
    }

    private func addText(name: String, value: String) {
        let attachment = XCTAttachment(
            data: Data(value.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
