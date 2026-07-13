import Foundation
import Observation

/// Main-actor state machine the menu renders from. Derives a display state
/// from the two contract signals — `runtime.json` (plus its pid stale rule)
/// and the health route — and forwards lifecycle intents to the controller.
///
/// @MainActor is justified here: this type exists solely to feed SwiftUI.
/// All file/process/network work happens in `ReleaseController` (actor) and
/// `HealthProbe` (async), reached through awaits.
@MainActor
@Observable
public final class ServerMonitor {
    public enum DisplayState: Sendable, Equatable {
        /// DEVIDE_RELEASE_ROOT is not set; the host has nothing to supervise.
        case noRelease
        case stopped
        case starting
        case ready
        /// Contract file present and pid alive, but the health route does
        /// not answer.
        case unhealthy
        case stopping

        public var symbolName: String {
            switch self {
            case .noRelease: "questionmark.circle"
            case .stopped: "stop.circle"
            case .starting, .stopping: "hourglass.circle"
            case .ready: "terminal.fill"
            case .unhealthy: "exclamationmark.triangle"
            }
        }

        public var label: String {
            switch self {
            case .noRelease: "No release configured"
            case .stopped: "Stopped"
            case .starting: "Starting…"
            case .ready: "Running"
            case .unhealthy: "Not responding"
            case .stopping: "Stopping…"
            }
        }
    }

    public private(set) var state: DisplayState
    public private(set) var status: RuntimeStatus?
    public private(set) var health: HealthReport?
    public private(set) var lastError: String?

    public private(set) var paths: HostPaths?
    private var controller: ReleaseController?
    private var pollTask: Task<Void, Never>?

    public init(paths: HostPaths? = HostPaths.detect()) {
        self.paths = paths
        self.controller = paths.map { ReleaseController(paths: $0) }
        self.state = paths == nil ? .noRelease : .stopped
    }

    /// Adopt an operator-chosen release ("Choose Release…") without a
    /// relaunch. No-op while a lifecycle transition is in flight.
    public func reconfigure(paths newPaths: HostPaths) {
        guard state != .starting, state != .stopping else { return }
        paths = newPaths
        controller = ReleaseController(paths: newPaths)
        status = nil
        health = nil
        lastError = nil
        state = .stopped
        startPolling()
    }

    public func startPolling(every interval: Duration = .seconds(2)) {
        guard pollTask == nil, paths != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func start() {
        perform(transition: .starting) { try await $0.start() }
    }

    public func stop() {
        let status = status
        perform(transition: .stopping) { try await $0.stop(status: status) }
    }

    public func restart() {
        let status = status
        perform(transition: .stopping) { try await $0.restart(status: status) }
    }

    /// Doc'd quit semantics: quitting the host stops the server by default.
    /// (The menu offers an explicit leave-it-running variant.)
    public func shutdownForQuit() async {
        stopPolling()
        guard let controller, status != nil || state == .starting else { return }
        try? await controller.stop(status: status)
    }

    private func perform(
        transition: DisplayState,
        _ operation: @escaping @Sendable (ReleaseController) async throws -> Void
    ) {
        guard let controller else { return }
        state = transition
        lastError = nil
        Task {
            do {
                try await operation(controller)
            } catch {
                lastError = String(describing: error)
            }
            await tick()
        }
    }

    public func tick() async {
        guard let paths, let controller else { return }
        let phase = await controller.phase

        switch RuntimeStatus.read(at: paths.statusFile) {
        case .failure:
            status = nil
            health = nil
            switch phase {
            case .starting: state = .starting
            case .stopping: state = .stopping
            case .idle: state = .stopped
            }

        case .success(let current):
            status = current
            if !current.isPidAlive {
                // Stale rule: the file survived a crash. Report as stopped;
                // the next successful boot overwrites the file.
                health = nil
                state = .stopped
            } else if let report = await HealthProbe.probe(baseURL: current.baseURL) {
                health = report
                state = phase == .stopping ? .stopping : .ready
            } else {
                health = nil
                state = phase == .starting ? .starting : .unhealthy
            }
        }
    }
}
