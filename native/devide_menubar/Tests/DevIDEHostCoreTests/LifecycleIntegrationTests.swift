import Foundation
import Testing

@testable import CaseinHostCore

/// End-to-end lifecycle test against a real desktop release — the same loop
/// casein-host-cli drives by hand, but self-asserting, so it can run as a
/// regression gate: start → contract file appears → health confirms the
/// published identity → graceful stop removes the file → epmd drops the
/// node name → restart comes up with a fresh pid.
///
/// Gated on DEVIDE_RELEASE_ROOT so `swift test` stays green without a
/// release. Run it with:
///
///     DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/casein \
///       /usr/bin/swift test --filter LifecycleIntegration
///
/// Uses a throwaway data dir, so the operator's real
/// ~/Library/Application Support/Casein (and its secrets) are untouched.
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["DEVIDE_RELEASE_ROOT"]?.isEmpty == false,
        "requires DEVIDE_RELEASE_ROOT pointing at a desktop-capable release"
    ),
    .serialized
)
struct LifecycleIntegrationTests {
    private func makePaths() throws -> HostPaths {
        let releaseRoot = URL(
            filePath: ProcessInfo.processInfo.environment["DEVIDE_RELEASE_ROOT"]!
        ).standardizedFileURL
        try #require(
            FileManager.default.isExecutableFile(
                atPath: releaseRoot.appending(path: "bin/casein").path),
            "no executable bin/casein under \(releaseRoot.path)")

        let dataDir = FileManager.default.temporaryDirectory
            .appending(path: "devide-host-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return HostPaths(dataDir: dataDir, releaseRoot: releaseRoot)
    }

    private func waitForStatus(
        at paths: HostPaths, timeout: Duration = .seconds(30)
    ) async -> RuntimeStatus? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if case .success(let status) = RuntimeStatus.read(at: paths.statusFile) {
                return status
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func waitForRemoval(
        at paths: HostPaths, timeout: Duration = .seconds(20)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if case .failure(.missing) = RuntimeStatus.read(at: paths.statusFile) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    @Test func fullStartStopRestartLoop() async throws {
        let paths = try makePaths()
        defer {
            try? HostSecrets.deleteFromKeychain(at: paths.hostSecretsFile)
            try? FileManager.default.removeItem(at: paths.dataDir)
        }
        // Unique node name: the crash-recovery suite may be booting its own
        // release concurrently.
        let releaseNode = "devide_lifecycle_e2e_\(UInt32.random(in: 0..<UInt32.max))"
        let controller = ReleaseController(paths: paths, releaseNode: releaseNode)

        // Start: migrate + daemon; the contract file appears once the
        // endpoint is bound (~4s in the phase-1 smoke).
        try await controller.start()
        let status = await waitForStatus(at: paths)
        let started = try #require(status, "runtime.json never appeared after start")
        #expect(started.schema == 1)
        #expect(started.status == "ready")
        #expect(started.isPidAlive)

        // Secrets live in Keychain; no reusable credential file remains.
        #expect(!FileManager.default.fileExists(atPath: paths.hostSecretsFile.path))

        // Health route confirms the published identity.
        let health = await HealthProbe.probe(baseURL: started.baseURL)
        let report = try #require(health, "health route did not answer at \(started.baseURL)")
        #expect(report.status == "ready")
        #expect(report.port == started.port)
        #expect(report.version == started.version)
        #expect((report.uptimeMs ?? 0) > 0)

        // The cockpit itself is closed to arbitrary loopback callers. The
        // host-minted URL exchanges its launch token for a browser session
        // and follows the clean-URL redirect to a successful page.
        let unauthenticated = try await URLSession(configuration: .ephemeral)
            .data(from: started.baseURL).1 as? HTTPURLResponse
        #expect(unauthenticated?.statusCode == 401)
        let launchURL = try await controller.cockpitURL(for: started)
        let authenticated = try await URLSession(configuration: .ephemeral)
            .data(from: launchURL).1 as? HTTPURLResponse
        #expect(authenticated?.statusCode == 200)
        #expect(authenticated?.url?.query == nil)

        // Recreate the controller like a menu-host relaunch while its daemon
        // remains alive. Restart must adopt, rather than rotate away from,
        // the occupied port in the live contract. This also proves graceful
        // stop and epmd name drain under the same RELEASE_NODE.
        let attachedController = ReleaseController(paths: paths, releaseNode: releaseNode)
        try await attachedController.restart(status: started)
        let restarted = try #require(
            await waitForStatus(at: paths), "runtime.json never reappeared after restart")
        #expect(restarted.pid != started.pid)
        #expect(restarted.port == started.port)
        #expect(restarted.isPidAlive)

        let secondHealth = await HealthProbe.probe(baseURL: restarted.baseURL)
        #expect(secondHealth != nil, "health route did not answer after restart")

        // The consumed claim remains blocked after the BEAM and replay-store
        // process restart; DETS carries its nonce through the acceptance window.
        let replayedAfterRestart = try await URLSession(configuration: .ephemeral)
            .data(from: launchURL).1 as? HTTPURLResponse
        #expect(replayedAfterRestart?.statusCode == 401)

        try await attachedController.stop(status: restarted)
        #expect(await waitForRemoval(at: paths), "runtime.json survived the final stop")
    }
}
