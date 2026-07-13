import AppKit
import DevIDEHostCore
import SwiftUI

struct MenuContent: View {
    let monitor: ServerMonitor

    var body: some View {
        header
        Divider()
        openSection
        lifecycleSection
        errorSection
        Divider()
        utilitySection
        Divider()
        quitSection
    }

    @ViewBuilder
    private var header: some View {
        Text(headerText)
        if let status = monitor.status {
            Text("v\(status.version) · \(status.revision.prefix(7))")
        }
    }

    private var headerText: String {
        if let port = monitor.status?.port, monitor.state == .ready {
            return "DevIDE — Running on :\(port)"
        }
        return "DevIDE — \(monitor.state.label)"
    }

    @ViewBuilder
    private var openSection: some View {
        if let base = monitor.status?.baseURL, monitor.state == .ready {
            Button("Open DevIDE") {
                NSWorkspace.shared.open(base)
            }
            .keyboardShortcut("o")

            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(base.absoluteString, forType: .string)
            }
            Divider()
        }
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        switch monitor.state {
        case .stopped:
            Button("Start Server") { monitor.start() }
        case .ready, .unhealthy:
            Button("Restart Server") { monitor.restart() }
            Button("Stop Server") { monitor.stop() }
        case .starting, .stopping:
            Text(monitor.state.label)
        case .noRelease:
            Text("Set DEVIDE_RELEASE_ROOT and relaunch")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = monitor.lastError {
            Divider()
            Text(error).lineLimit(3)
        }
    }

    @ViewBuilder
    private var utilitySection: some View {
        if let paths = monitor.paths {
            Button("Open Logs") {
                NSWorkspace.shared.open(paths.logsDir)
            }
            Button("Open Data Folder") {
                NSWorkspace.shared.open(paths.dataDir)
            }
        }
    }

    @ViewBuilder
    private var quitSection: some View {
        // Doc'd semantics: Quit stops the server; the explicit variant
        // leaves it running.
        Button("Quit DevIDE") {
            Task {
                await monitor.shutdownForQuit()
                NSApplication.shared.terminate(nil)
            }
        }
        .keyboardShortcut("q")

        Button("Quit, Leave Server Running") {
            NSApplication.shared.terminate(nil)
        }
    }
}
