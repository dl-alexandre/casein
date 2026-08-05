import XCTest

/// Physical-device acceptance for the explicit, synthetic-only renderer gate.
/// The signed app is launched externally through `devicectl` before each test.
/// This avoids Xcode replacing Mob's signed bundle with the provisioning stub.
final class CaseinTerminalRendererProbeUITests: XCTestCase {
    private let bundleIdentifier = "com.alexandrefamilyfarm.casein-mob"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testSignedSyntheticRendererLifecycleAndPrivacyBoundary() throws {
        XCTAssertNotEqual(app.state, .notRunning, "Launch the flagged signed app first")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        let root = app.otherElements["casein.terminal.probe.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10))

        // SwiftUI can expose a custom-labelled Text as either StaticText or
        // Other across iOS releases; the identifier is the stable contract.
        let metrics = app.descendants(matching: .any)["casein.terminal.probe.metrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(metrics, containing: "cycles 10", timeout: 10))
        XCTAssertTrue(stringValue(metrics).contains("renderer casein_canvas"))

        // Fixture pixels are Canvas-only. They must not enter the native
        // accessibility tree as a label or value.
        assertFixtureAbsentFromAccessibilityTree()

        let previousValue = stringValue(metrics)
        let recreate = app.descendants(matching: .any)["casein.terminal.probe.recreate"]
        XCTAssertTrue(recreate.isHittable)
        recreate.tap()
        XCTAssertTrue(waitForValueChange(metrics, from: previousValue, timeout: 5))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(root.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(timeout: 8))
        XCTAssertTrue(root.exists)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(timeout: 8))
        XCTAssertTrue(root.exists)
    }

    func testUnflaggedLaunchDoesNotExposeProbeRootOrControl() throws {
        XCTAssertNotEqual(app.state, .notRunning, "Launch the unflagged signed app first")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["casein.terminal.probe.root"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["casein.terminal.probe.recreate"].exists)
    }

    private func assertFixtureAbsentFromAccessibilityTree(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            "CASEIN SYNTHETIC TERMINAL",
            "renderer: canvas",
            "lifecycle: create resize destroy recreate",
            "privacy: fixture only"
        ]
        for element in app.descendants(matching: .any).allElementsBoundByAccessibilityElement {
            let exposed = [element.identifier, element.label, stringValue(element)]
                .joined(separator: "\n")
            for fragment in forbidden {
                XCTAssertFalse(
                    exposed.localizedCaseInsensitiveContains(fragment),
                    "Fixture fragment leaked through accessibility: \(fragment)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func stringValue(_ element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    private func waitForValue(
        _ element: XCUIElement,
        containing fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if stringValue(element).contains(fragment) { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        } while Date() < deadline
        return stringValue(element).contains(fragment)
    }

    private func waitForValueChange(
        _ element: XCUIElement,
        from oldValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if stringValue(element) != oldValue { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        } while Date() < deadline
        return stringValue(element) != oldValue
    }

    private func waitForLandscape(timeout: TimeInterval) -> Bool {
        waitForWindowShape(timeout: timeout) { $0.width > $0.height }
    }

    private func waitForPortrait(timeout: TimeInterval) -> Bool {
        waitForWindowShape(timeout: timeout) { $0.height > $0.width }
    }

    private func waitForWindowShape(
        timeout: TimeInterval,
        predicate: (CGRect) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate(app.windows.firstMatch.frame) { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        } while Date() < deadline
        return predicate(app.windows.firstMatch.frame)
    }
}
