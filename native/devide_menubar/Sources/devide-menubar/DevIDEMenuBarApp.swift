import AppKit
import DevIDEHostCore
import SwiftUI

@main
struct DevIDEMenuBarApp: App {
    @State private var monitor: ServerMonitor

    init() {
        // Menu bar extra only, no Dock icon. Packaged builds also set
        // LSUIElement in Info.plist; this covers `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        let monitor = ServerMonitor()
        monitor.startPolling()
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
