import Foundation
import Testing

@testable import DevIDEHostCore

/// Crash auto-restart against a real release: start via the monitor,
/// SIGKILL the BEAM (leaving a stale contract), and assert the conservative
/// supervision policy — crash detected, countdown scheduled with backoff,
/// server back to ready with a fresh pid, without any manual action.
///
/// Same gate as LifecycleIntegrationTests:
///
///     DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/dev_ide \
///       /usr/bin/swift test --filter CrashRecovery
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["DEVIDE_RELEASE_ROOT"]?.isEmpty == false,
        "requires DEVIDE_RELEASE_ROOT pointing at a desktop-capable release"
    ),
    .serialized
)
struct CrashRecoveryIntegrationTests {
    private func makePaths() throws -> HostPaths {
        let releaseRoot = URL(
            filePath: ProcessInfo.processInfo.environment["DEVIDE_RELEASE_ROOT"]!
        ).standardizedFileURL
        let dataDir = FileManager.default.temporaryDirectory
            .appending(path: "devide-host-crash-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return HostPaths(dataDir: dataDir, releaseRoot: releaseRoot)
    }

    @MainActor
    private func settle(
        _ monitor: ServerMonitor,
        until goal: @MainActor (ServerMonitor) -> Bool,
        timeout: Duration,
        what: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            await monitor.tick()
            if goal(monitor) { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
        Issue.record("timed out waiting for \(what); state=\(monitor.state)")
        throw CancellationError()
    }

    @MainActor
    @Test func sigkilledServerAutoRestartsWithFreshPid() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDir) }
        // Unique node name: the lifecycle suite may be booting its own
        // release concurrently under the default name.
        let monitor = ServerMonitor(
            paths: paths,
            releaseNode: "devide_crash_e2e_\(UInt32.random(in: 0..<UInt32.max))")

        monitor.start()
        try await settle(
            monitor, until: { $0.state == .ready }, timeout: .seconds(45),
            what: "initial ready")
        let first = try #require(monitor.status)

        // Hard crash: pid dies, contract file stays behind (stale).
        kill(first.pid, SIGKILL)

        try await settle(
            monitor, until: { $0.state == .crashed }, timeout: .seconds(10),
            what: "crash detection")
        let countdown = try #require(monitor.pendingRestartSeconds)
        #expect(countdown <= 5, "first crash must use the 5s rung, saw \(countdown)s")

        // No manual action: countdown elapses, restart runs, server is back.
        try await settle(
            monitor, until: { $0.state == .ready }, timeout: .seconds(60),
            what: "auto-restart to ready")
        let second = try #require(monitor.status)
        #expect(second.pid != first.pid)
        #expect(monitor.pendingRestartSeconds == nil)

        // Cleanup through the monitor's own stop path.
        monitor.stop()
        try await settle(
            monitor, until: { $0.state == .stopped }, timeout: .seconds(30),
            what: "final stop")
    }

    @MainActor
    @Test func staleContractWithoutIntentStaysStopped() async throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDir) }

        // A stale file from "some earlier session": dead pid, never seen
        // ready by this monitor. The host must not surprise-start anything.
        let probe = Process()
        probe.executableURL = URL(filePath: "/usr/bin/true")
        try probe.run()
        probe.waitUntilExit()

        var payload = try JSONSerialization.jsonObject(
            with: Data(
                #"""
                {"schema":1,"status":"ready","port":1,"base_url":"http://127.0.0.1:1",
                 "pid":1,"version":"0","revision":"0","started_at":"2026-01-01T00:00:00Z"}
                """#.utf8)) as! [String: Any]
        payload["pid"] = probe.processIdentifier
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: paths.statusFile)

        let monitor = ServerMonitor(paths: paths)
        await monitor.tick()
        #expect(monitor.state == .stopped)
        #expect(monitor.pendingRestartSeconds == nil)
    }
}
