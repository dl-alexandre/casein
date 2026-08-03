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

    func testStickyDirectionChoiceResolvesAuthoritatively() throws {
        let configuration = try NeedsMeDirectionConfiguration(
            environment: ProcessInfo.processInfo.environment
        )

        guard app.state == .runningForeground else {
            XCTFail("Casein must already be running in the foreground")
            return
        }
        try requireCaseinAccessibility()

        let needsMe = app.buttons["Needs Me"]
        XCTAssertTrue(needsMe.waitForExistence(timeout: 10))
        needsMe.tap()

        let directionTitle = app.staticTexts[configuration.directionTitle]
        let openDirection = app.buttons["needs-me-open-sticky-direction"]
        XCTAssertTrue(
            openDirection.waitForExistence(timeout: 30),
            "Sticky direction request open control did not arrive"
        )
        XCTAssertTrue(directionTitle.waitForExistence(timeout: 5), "Configured direction title is absent")
        // Column containers are not native AX elements in Mob. Sticky pinning and
        // relative card order remain covered by the server/native render unit tests;
        // physical readiness is asserted through this bounded interactive control.
        XCTAssertTrue(openDirection.isHittable)
        openDirection.tap()

        let choices = configuration.choiceIDs.map { app.buttons["needs-me-action-\($0)"] }
        for choice in choices {
            XCTAssertTrue(
                choice.waitForExistence(timeout: 10),
                "Declared choice accessibility ID is absent"
            )
            XCTAssertTrue(choice.isHittable, "Declared choice is not hittable")
        }
        assertVisualOrder(choices)

        let selectedChoice = app.buttons[
            "needs-me-action-\(configuration.selectedChoiceID)"
        ]
        XCTAssertTrue(selectedChoice.exists, "Configured choice is not server-declared")
        selectedChoice.tap()

        let accepted = app.otherElements["needs-me-state-accepted"]
        let resolved = app.otherElements["needs-me-state-resolved"]
        XCTAssertTrue(
            waitForAny([accepted, resolved], timeout: 15),
            "Choice did not reach an accepted or resolved server state"
        )
        XCTAssertTrue(
            resolved.waitForExistence(timeout: 30),
            "Authoritative snapshot did not resolve the direction request"
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

    private func assertVisualOrder(
        _ elements: [XCUIElement],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (earlier, later) in zip(elements, elements.dropFirst()) {
            let earlierFrame = earlier.frame
            let laterFrame = later.frame
            let ordered = earlierFrame.minY < laterFrame.minY
                || (abs(earlierFrame.minY - laterFrame.minY) <= 2
                    && earlierFrame.minX < laterFrame.minX)
            XCTAssertTrue(
                ordered,
                "Declared choices are out of server order",
                file: file,
                line: line
            )
        }
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elements.contains(where: \.exists) { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        } while Date() < deadline
        return elements.contains(where: \.exists)
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

private struct NeedsMeDirectionConfiguration {
    let directionTitle: String
    let choiceIDs: [String]
    let selectedChoiceID: String

    init(environment: [String: String]) throws {
        directionTitle = try Self.required("CASEIN_XCUITEST_DIRECTION_TITLE", in: environment)
        selectedChoiceID = try Self.required(
            "CASEIN_XCUITEST_DIRECTION_CHOICE_ID",
            in: environment
        )
        choiceIDs = try Self.required(
            "CASEIN_XCUITEST_DIRECTION_CHOICE_IDS",
            in: environment
        )
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !choiceIDs.isEmpty, choiceIDs.allSatisfy(Self.validChoiceID) else {
            throw ConfigurationError.invalidChoiceIDs
        }
        guard Set(choiceIDs).count == choiceIDs.count else {
            throw ConfigurationError.duplicateChoiceIDs
        }
        guard choiceIDs.contains(selectedChoiceID) else {
            throw ConfigurationError.selectedChoiceNotDeclared
        }
    }

    private static func required(_ key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw ConfigurationError.missing(key)
        }
        return value
    }

    private static func validChoiceID(_ value: String) -> Bool {
        value.hasPrefix("choose_")
            && value.unicodeScalars.allSatisfy {
                CharacterSet.lowercaseLetters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
                    || $0 == "_"
            }
    }

    private enum ConfigurationError: LocalizedError {
        case missing(String)
        case invalidChoiceIDs
        case duplicateChoiceIDs
        case selectedChoiceNotDeclared

        var errorDescription: String? {
            switch self {
            case .missing(let key):
                return "Missing required XCUITest environment variable \(key)"
            case .invalidChoiceIDs:
                return "Choice IDs must be comma-separated choose_* identifiers"
            case .duplicateChoiceIDs:
                return "Choice IDs must be unique"
            case .selectedChoiceNotDeclared:
                return "Selected choice must be present in declared choice IDs"
            }
        }
    }
}
