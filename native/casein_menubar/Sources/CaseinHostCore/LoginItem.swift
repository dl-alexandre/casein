import Foundation
import ServiceManagement

/// Start-at-Login via `SMAppService.mainApp` (macOS 13+, the modern path —
/// no legacy `SMLoginItemSetEnabled` helper bundle).
///
/// Only meaningful when running from a real `.app`: a bare `swift run`
/// executable has no main-app service to register, so the menu hides the
/// toggle instead of offering one that throws. Note the registration binds
/// to the bundle's on-disk location — moving or deleting the `.app` breaks
/// the login item (fine for the spike; installed builds live in a stable
/// location).
public enum LoginItem {
    /// True when running from an `.app` bundle (the test runner's `.xctest`
    /// bundle and bare executables both report false).
    public static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user disabled (or must approve) the item in System Settings;
    /// register() alone cannot flip it back.
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Deep link to the Login Items pane for the requiresApproval case.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
