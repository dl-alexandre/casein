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
            return "Casein — Running on :\(port)"
        }
        return "Casein — \(monitor.state.label)"
    }

    @ViewBuilder
    private var openSection: some View {
        if monitor.status != nil, monitor.state == .ready {
            Button("Open Casein") {
                Task {
                    if let url = await monitor.cockpitURL() {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .keyboardShortcut("o")

            Button("Copy URL") {
                Task {
                    if let url = await monitor.cleanCockpitURL() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }

            if monitor.lanEnabled {
                Button("Open DevIDE on LAN") {
                    Task {
                        if let url = await monitor.lanCockpitURL() {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Button("Copy LAN URL") {
                    Task {
                        if let url = await monitor.lanURL() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
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
        case .crashed:
            if let seconds = monitor.pendingRestartSeconds {
                Text("Crashed — restarting in \(seconds)s")
            }
            Button("Restart Now") { monitor.restart() }
            Button("Cancel Auto-Restart") { monitor.cancelAutoRestart() }
        case .noRelease:
            Button("Choose Release…") { chooseRelease() }
        }
    }

    private func chooseRelease() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select a Casein release directory (contains bin/casein)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let paths = HostPaths.choose(releaseRoot: url) {
            monitor.reconfigure(paths: paths)
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
        Toggle("Allow Trusted LAN Access", isOn: lanAccessBinding)
            .disabled(monitor.state == .starting || monitor.state == .stopping)
        if let paths = monitor.paths {
            Button("Open Logs") {
                NSWorkspace.shared.open(paths.logsDir)
            }
            Button("Open Data Folder") {
                NSWorkspace.shared.open(paths.dataDir)
            }
        }
        loginItemSection
    }

    private var lanAccessBinding: Binding<Bool> {
        Binding(
            get: { monitor.lanEnabled },
            set: { monitor.setLANEnabled($0) }
        )
    }

    @ViewBuilder
    private var loginItemSection: some View {
        // Hidden under `swift run`: a bare executable has no main-app
        // service to register.
        if LoginItem.isBundled {
            Toggle("Start at Login", isOn: startAtLoginBinding)
        }
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                } catch {
                    NSLog("Start at Login toggle failed: \(error)")
                }
                // register() can land in requiresApproval (user disabled it
                // in System Settings earlier); only they can flip it back.
                if LoginItem.requiresApproval {
                    LoginItem.openSystemSettings()
                }
            }
        )
    }

    @ViewBuilder
    private var quitSection: some View {
        // Doc'd semantics: Quit stops the server; the explicit variant
        // leaves it running.
        Button("Quit Casein") {
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
