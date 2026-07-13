import AppKit
import SwiftUI

@main
struct DevIDEMenuBarApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @StateObject private var model = HostModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            // SF Symbols render as template images, so the icon adapts to
            // light/dark menu bars for free.
            Image(systemName: model.state.symbolName)
        }
    }
}

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces with LSUIElement: never show a Dock icon, even when
        // launched as a bare executable during development.
        NSApp.setActivationPolicy(.accessory)
    }
}
