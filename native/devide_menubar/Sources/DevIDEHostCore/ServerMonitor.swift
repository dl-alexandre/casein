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
        /// Crashed while the host wanted it running; auto-restart pending
        /// (see `pendingRestartSeconds`).
        case crashed

        /// Brand glyph is `greaterthanorequalto.square` — filled while the
        /// server is running, outline while stopped. Transitions and error
        /// states keep distinct shapes so they read at menubar size.
        public var symbolName: String {
            switch self {
            case .noRelease: "questionmark.square"
            case .stopped: "greaterthanorequalto.square"
            case .starting, .stopping: "hourglass"
            case .ready: "greaterthanorequalto.square.fill"
            case .unhealthy: "exclamationmark.triangle"
            case .crashed: "arrow.clockwise"
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
            case .crashed: "Crashed"
            }
        }
    }

    public private(set) var state: DisplayState
    public private(set) var status: RuntimeStatus?
    public private(set) var health: HealthReport?
    public private(set) var lastError: String?
    /// Countdown to the pending crash auto-restart, for the menu.
    public private(set) var pendingRestartSeconds: Int?

    public private(set) var paths: HostPaths?
    private var controller: ReleaseController?
    private var pollTask: Task<Void, Never>?
    private var autoRestartTask: Task<Void, Never>?
    private var backoff = RestartBackoff()
    /// Supervision intent: true once the host started the server or observed
    /// it ready this session. A stale contract found *without* intent (e.g.
    /// at host launch, after a crash while the host wasn't running) reads as
    /// stopped — the host never surprise-starts a server.
    private var desiredRunning = false

    private let releaseNode: String

    public init(
        paths: HostPaths? = HostPaths.detect(),
        releaseNode: String = ReleaseController.defaultReleaseNode
    ) {
        self.paths = paths
        self.releaseNode = releaseNode
        self.controller = paths.map { ReleaseController(paths: $0, releaseNode: releaseNode) }
        self.state = paths == nil ? .noRelease : .stopped
    }

    /// Adopt an operator-chosen release ("Choose Release…") without a
    /// relaunch. No-op while a lifecycle transition is in flight.
    public func reconfigure(paths newPaths: HostPaths) {
        guard state != .starting, state != .stopping else { return }
        cancelAutoRestart()
        desiredRunning = false
        backoff.reset()
        paths = newPaths
        controller = ReleaseController(paths: newPaths, releaseNode: releaseNode)
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
        cancelAutoRestart()
        desiredRunning = true
        backoff.reset()
        perform(transition: .starting) { try await $0.start() }
    }

    public func stop() {
        cancelAutoRestart()
        desiredRunning = false
        let status = status
        perform(transition: .stopping) { try await $0.stop(status: status) }
    }

    public func restart() {
        cancelAutoRestart()
        desiredRunning = true
        backoff.reset()
        let status = status
        perform(transition: .stopping) { try await $0.restart(status: status) }
    }

    /// Dismiss a pending crash auto-restart: the server stays down until a
    /// manual Start.
    public func cancelAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = nil
        pendingRestartSeconds = nil
        if state == .crashed {
            desiredRunning = false
            state = .stopped
        }
    }

    /// Doc'd quit semantics: quitting the host stops the server by default.
    /// (The menu offers an explicit leave-it-running variant.)
    public func shutdownForQuit() async {
        stopPolling()
        cancelAutoRestart()
        desiredRunning = false
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
                // Stale rule: the file survived a crash. With supervision
                // intent, schedule an auto-restart (conservative policy:
                // stale only — a slow-but-alive node must never be
                // restart-looped); without intent, report stopped.
                health = nil
                switch (phase, autoRestartTask) {
                case (.starting, _): state = .starting
                case (.stopping, _): state = .stopping
                case (.idle, .some): state = .crashed
                case (.idle, .none) where desiredRunning: scheduleAutoRestart()
                case (.idle, .none): state = .stopped
                }
            } else if let report = await HealthProbe.probe(baseURL: current.baseURL) {
                health = report
                desiredRunning = true
                state = phase == .stopping ? .stopping : .ready
            } else {
                health = nil
                state = phase == .starting ? .starting : .unhealthy
            }
        }
    }

    private func scheduleAutoRestart() {
        let delay = backoff.nextDelay()
        state = .crashed
        lastError = nil
        let seconds = max(1, Int(delay.components.seconds))
        pendingRestartSeconds = seconds

        autoRestartTask = Task { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.pendingRestartSeconds = remaining
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingRestartSeconds = nil
            self.state = .starting
            self.lastError = nil
            // Full restart, not bare start: the dead pid clears instantly
            // and the epmd drain still guards the name. Deliberately does
            // NOT reset the backoff ladder — only manual actions do.
            // autoRestartTask stays set until the NEW boot publishes its
            // contract: the restart command returns ~2s before runtime.json
            // is overwritten, and in that window the stale old file would
            // otherwise read as a second crash and double-schedule. If the
            // boot fails, the deadline releases the handle and the next
            // tick escalates to the following backoff rung — which is the
            // correct crash-loop behavior.
            if let controller = self.controller {
                do {
                    try await controller.restart(status: self.status)
                } catch {
                    self.lastError = String(describing: error)
                }
            }
            if let statusFile = self.paths?.statusFile {
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(45)
                while clock.now < deadline, !Task.isCancelled {
                    if case .success(let fresh) = RuntimeStatus.read(at: statusFile),
                        fresh.isPidAlive
                    {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            self.autoRestartTask = nil
            await self.tick()
        }
    }
}
