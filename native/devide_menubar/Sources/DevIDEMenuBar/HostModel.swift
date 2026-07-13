import AppKit
import Foundation

/// The host's whole brain: a 2s poll of the status contract plus the
/// lifecycle actions the menu exposes. Deliberately no product state — see
/// docs/desktop/platform_architecture.md "macOS desktop host".
@MainActor
final class HostModel: ObservableObject {
    /// What the host itself is doing, layered over the observed RuntimeState.
    enum Activity: Equatable {
        case idle
        case starting
        case stopping
        case restarting

        var label: String? {
            switch self {
            case .idle: return nil
            case .starting: return "Starting…"
            case .stopping: return "Stopping…"
            case .restarting: return "Restarting…"
            }
        }
    }

    let settings = HostSettings()

    @Published private(set) var state: RuntimeState = .stopped
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit { pollTask?.cancel() }

    // MARK: - Observation

    func refresh() async {
        var next = StatusFile.read(at: settings.statusFile)
        if case .unhealthy(let status, _) = next {
            next = await StatusFile.probeHealth(for: status)
        }
        state = next
        if case .ready = next, activity == .starting || activity == .restarting {
            activity = .idle
        }
        if case .stopped = next, activity == .stopping {
            activity = .idle
        }
    }

    // MARK: - Menu-facing derived state

    var statusHeadline: String {
        if let label = activity.label { return label }
        switch state {
        case .stopped: return "DevIDE: stopped"
        case .stale: return "DevIDE: stopped (stale runtime.json)"
        case .ready: return "DevIDE: running"
        case .unhealthy: return "DevIDE: unhealthy"
        case .incompatible(let schema):
            return "DevIDE: unsupported status schema \(schema.map(String.init) ?? "?")"
        }
    }

    var statusDetail: String? {
        guard case .ready(let status, let health) = state else {
            if case .unhealthy(_, let reason) = state { return reason }
            return nil
        }
        return "v\(status.version) (\(status.revision)) on port \(health.port)"
    }

    var baseURL: URL? {
        if case .ready(let status, _) = state { return status.baseURL }
        return nil
    }

    var canStart: Bool {
        guard activity == .idle, settings.releaseRoot != nil else { return false }
        switch state {
        case .stopped, .stale: return true
        default: return false
        }
    }

    var canStop: Bool {
        guard activity == .idle else { return false }
        switch state {
        case .ready, .unhealthy: return true
        default: return false
        }
    }

    // MARK: - Lifecycle actions

    func start() {
        runLifecycle(.starting) { try await self.doStart() }
    }

    func stop() {
        runLifecycle(.stopping) { try await self.doStop() }
    }

    func restart() {
        runLifecycle(.restarting) {
            try await self.doStop()
            try await self.doStart()
        }
    }

    /// Contract: Quit stops the server by default; the alternate menu item
    /// leaves it running.
    func quitStoppingServer() {
        Task {
            activity = .stopping
            try? await doStop()
            NSApp.terminate(nil)
        }
    }

    private func runLifecycle(_ activity: Activity, _ body: @escaping () async throws -> Void) {
        guard self.activity == .idle else { return }
        self.activity = activity
        lastError = nil
        Task {
            do {
                try await body()
            } catch {
                lastError = error.localizedDescription
                self.activity = .idle
            }
            await refresh()
        }
    }

    private func doStart() async throws {
        guard let releaseRoot = settings.releaseRoot else {
            throw SetupError.noReleaseConfigured
        }
        let secrets = try HostSecrets.loadOrCreate(at: settings.secretsFile)
        let env = ReleaseCommands.environment(settings: settings, secrets: secrets)

        // A stale runtime.json would make the poll misread the fresh boot.
        if case .stale = StatusFile.read(at: settings.statusFile) {
            try? FileManager.default.removeItem(at: settings.statusFile)
        }

        try await ReleaseCommands.run(
            script: "migrate", releaseRoot: releaseRoot,
            environment: env, logsDir: settings.hostLogsDir
        )
        try await ReleaseCommands.run(
            script: "dev_ide", arguments: ["daemon"], releaseRoot: releaseRoot,
            environment: env, logsDir: settings.hostLogsDir
        )
        // runtime.json appears once the endpoint is bound; the poll flips the
        // menu to "running" (observed ~4s on a real release boot).
    }

    private func doStop() async throws {
        guard let releaseRoot = settings.releaseRoot else {
            throw SetupError.noReleaseConfigured
        }
        let pid = state.runtimeStatus?.pid
        let secrets = try HostSecrets.loadOrCreate(at: settings.secretsFile)
        let env = ReleaseCommands.environment(settings: settings, secrets: secrets)

        try await ReleaseCommands.run(
            script: "dev_ide", arguments: ["stop"], releaseRoot: releaseRoot,
            environment: env, logsDir: settings.hostLogsDir
        )
        if let pid {
            _ = await ReleaseCommands.waitForExit(pid: pid, timeout: 20)
        }
        // Restarting before epmd drops the name fails with "name in use".
        await ReleaseCommands.drainEpmd(
            releaseRoot: releaseRoot, nodeName: settings.releaseNode, timeout: 15
        )
    }

    enum SetupError: LocalizedError {
        case noReleaseConfigured

        var errorDescription: String? {
            "No release configured — use “Choose Release…” to pick the directory containing bin/dev_ide."
        }
    }

    // MARK: - Helpers the menu calls

    func openCockpit() {
        guard let url = baseURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyBaseURL() {
        guard let url = baseURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func openDataFolder() {
        try? FileManager.default.createDirectory(at: settings.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.dataDir)
    }

    func openLogs() {
        // Release logs when a release is configured (bin/dev_ide daemon logs
        // to <release>/tmp/log), host command logs otherwise.
        if let releaseLogs = settings.releaseRoot?.appendingPathComponent("tmp/log"),
           FileManager.default.fileExists(atPath: releaseLogs.path) {
            NSWorkspace.shared.open(releaseLogs)
            return
        }
        try? FileManager.default.createDirectory(at: settings.hostLogsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.hostLogsDir)
    }

    func chooseRelease() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick the DevIDE release directory (the one containing bin/dev_ide)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let launcher = url.appendingPathComponent("bin/dev_ide")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            lastError = "\(url.path) has no executable bin/dev_ide."
            return
        }
        settings.releaseRoot = url
        lastError = nil
        objectWillChange.send()
    }
}
