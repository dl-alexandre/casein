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

        selectedDevbox.tap()

        let validatingFeed = app.staticTexts["Saved profile · validating live access"]
        let connectingOrigin = app.staticTexts["Devbox · Connecting"]
        let transition = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                validatingFeed.exists || connectingOrigin.exists
            },
            object: app
        )

        XCTAssertTrue(
            XCTWaiter.wait(for: [transition], timeout: 10) == .completed,
            "Reconnect did not expose its validating state"
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
}
