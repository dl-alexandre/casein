import AppKit
import CaseinHostCore
import SwiftUI

@main
struct CaseinMenuBarApp: App {
    @State private var monitor: ServerMonitor

    init() {
        // Menu bar extra only, no Dock icon. Packaged builds also set
        // LSUIElement in Info.plist; this covers `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        let monitor = ServerMonitor()
        monitor.startPolling()
        // A packaged desktop host owns its embedded release. Launching it —
        // including through SMAppService at login — restores Casein without a
        // second manual "Start Server" action after every reboot.
        if monitor.paths?.releaseRoot.path.contains(".app/Contents/Resources/release") == true {
            Task { @MainActor in
                await monitor.tick()
                if monitor.state == .stopped { monitor.start() }
            }
        }
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.state.symbolName)
        }
    }
}
