import SwiftUI

/// The v1 menu from docs/desktop/platform_architecture.md "Host
/// responsibilities": status header, Open, lifecycle, folder helpers, Quit
/// with a leave-running variant. Login item, recent workspaces, and pairing
/// helpers are phase 3.
struct MenuContent: View {
    @EnvironmentObject private var model: HostModel

    var body: some View {
        Text(model.statusHeadline)
        if let detail = model.statusDetail {
            Text(detail)
        }
        if let error = model.lastError {
            Text(error)
        }

        Divider()

        Button("Open DevIDE") { model.openCockpit() }
            .disabled(model.baseURL == nil)
        Button("Copy Base URL") { model.copyBaseURL() }
            .disabled(model.baseURL == nil)

        Divider()

        Button("Start") { model.start() }
            .disabled(!model.canStart)
        Button("Stop") { model.stop() }
            .disabled(!model.canStop)
        Button("Restart") { model.restart() }
            .disabled(!model.canStop)

        Divider()

        Button("Open Data Folder") { model.openDataFolder() }
        Button("Open Logs") { model.openLogs() }
        Button("Choose Release…") { model.chooseRelease() }

        Divider()

        // Contract: Quit stops the server by default. Two explicit items
        // instead of an option-key alternate for now — see README.
        Button("Quit and Stop Server") { model.quitStoppingServer() }
        Button("Quit, Leave Server Running") { NSApp.terminate(nil) }
    }
}
