import XCTest

final class CaseinMobFeedLifecycleUITests: XCTestCase {
    func testCanonicalDevboxReconnectWithoutRelaunch() throws {
        continueAfterFailure = false

        let app = XCUIApplication(
            bundleIdentifier: "com.alexandrefamilyfarm.casein-mob"
        )

        switch app.state {
        case .runningForeground:
            break
        case .runningBackground, .runningBackgroundSuspended:
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 10),
                "Casein did not return to the foreground"
            )
        default:
            XCTFail("Casein must already be running")
            return
        }

        let canonicalOrigin = app.staticTexts["https://casein.devbox.milcgroup.com"]
        let selectedDevbox = app.buttons["Selected · Devbox"]
        let authenticatedFeed = app.staticTexts["Authenticated live feed"]

        XCTAssertTrue(
            canonicalOrigin.waitForExistence(timeout: 15),
            "Canonical origin is not visible"
        )
        XCTAssertTrue(
            selectedDevbox.waitForExistence(timeout: 15),
            "Canonical Devbox is not selected"
        )
        XCTAssertTrue(
            authenticatedFeed.waitForExistence(timeout: 15),
            "Canonical feed is not authenticated"
        )
        XCTAssertTrue(selectedDevbox.isHittable, "Selected Devbox control is not hittable")

        let reconnectNotice = app.staticTexts[
            "Switched origin; refreshing authoritative state"
        ]
        let noticeClearedBeforeTap = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !reconnectNotice.exists },
            object: app
        )

        XCTAssertTrue(
            XCTWaiter.wait(for: [noticeClearedBeforeTap], timeout: 10) == .completed,
            "Previous reconnect notice did not clear"
        )

        selectedDevbox.tap()

        let validatingFeed = app.staticTexts["Saved profile · validating live access"]
        let connectingOrigin = app.staticTexts["Devbox · Connecting"]

        XCTAssertTrue(
            Self.waitForReconnectTransition(
                notice: reconnectNotice,
                validating: validatingFeed,
                connecting: connectingOrigin,
                limit: 10
            ),
            "Reconnect did not acknowledge the request or expose its validating state"
        )

        let noticeClearedAfterSnapshot = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !reconnectNotice.exists },
            object: app
        )

        XCTAssertTrue(
            XCTWaiter.wait(for: [noticeClearedAfterSnapshot], timeout: 30) == .completed,
            "Reconnect notice did not clear after authoritative refresh"
        )
        XCTAssertTrue(
            authenticatedFeed.waitForExistence(timeout: 30),
            "Authenticated feed did not return"
        )
        XCTAssertTrue(
            canonicalOrigin.waitForExistence(timeout: 10),
            "Canonical origin changed during reconnect"
        )
        XCTAssertTrue(
            selectedDevbox.waitForExistence(timeout: 10),
            "Selected origin changed during reconnect"
        )
    }

    private static func waitForReconnectTransition(
        notice: XCUIElement,
        validating: XCUIElement,
        connecting: XCUIElement,
        limit: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(limit)

        repeat {
            if reconnectTransitionObserved(
                acknowledged: notice.exists,
                validating: validating.exists,
                connecting: connecting.exists
            ) {
                return true
            }

            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        } while Date() < deadline

        return reconnectTransitionObserved(
            acknowledged: notice.exists,
            validating: validating.exists,
            connecting: connecting.exists
        )
    }

    private static func reconnectTransitionObserved(
        acknowledged: Bool,
        validating: Bool,
        connecting: Bool
    ) -> Bool {
        acknowledged || validating || connecting
    }
}
