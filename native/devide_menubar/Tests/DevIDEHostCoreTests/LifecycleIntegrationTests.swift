import Foundation
import Testing

@testable import DevIDEHostCore

/// End-to-end lifecycle test against a real desktop release — the same loop
/// devide-host-cli drives by hand, but self-asserting, so it can run as a
/// regression gate: start → contract file appears → health confirms the
/// published identity → graceful stop removes the file → epmd drops the
/// node name → restart comes up with a fresh pid.
///
/// Gated on DEVIDE_RELEASE_ROOT so `swift test` stays green without a
/// release. Run it with:
///
///     DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/dev_ide \
///       /usr/bin/swift test --filter LifecycleIntegration
///
/// Uses a throwaway data dir, so the operator's real
/// ~/Library/Application Support/DevIDE (and its secrets) are untouched.
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
                atPath: releaseRoot.appending(path: "bin/dev_ide").path),
            "no executable bin/dev_ide under \(releaseRoot.path)")

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
        defer { try? FileManager.default.removeItem(at: paths.dataDir) }
        let controller = ReleaseController(paths: paths)

        // Start: migrate + daemon; the contract file appears once the
        // endpoint is bound (~4s in the phase-1 smoke).
        try await controller.start()
        let status = await waitForStatus(at: paths)
        let started = try #require(status, "runtime.json never appeared after start")
        #expect(started.schema == 1)
        #expect(started.status == "ready")
        #expect(started.isPidAlive)

        // Secrets were generated with owner-only permissions.
        let secretAttrs = try FileManager.default.attributesOfItem(
            atPath: paths.hostSecretsFile.path)
        #expect((secretAttrs[.posixPermissions] as? Int) == 0o600)

        // Health route confirms the published identity.
        let health = await HealthProbe.probe(baseURL: started.baseURL)
        let report = try #require(health, "health route did not answer at \(started.baseURL)")
        #expect(report.status == "ready")
        #expect(report.port == started.port)
        #expect(report.version == started.version)
        #expect((report.uptimeMs ?? 0) > 0)

        // Stop: file removed on graceful shutdown, pid exits.
        try await controller.stop(status: started)
        #expect(await waitForRemoval(at: paths), "runtime.json survived a graceful stop")
        #expect(!started.isPidAlive)

        // Restart proves the epmd name actually drains (the "name in use"
        // trap): a second boot under the same RELEASE_NODE must come up.
        try await controller.restart(status: nil)
        let restarted = try #require(
            await waitForStatus(at: paths), "runtime.json never reappeared after restart")
        #expect(restarted.pid != started.pid)
        #expect(restarted.isPidAlive)

        let secondHealth = await HealthProbe.probe(baseURL: restarted.baseURL)
        #expect(secondHealth != nil, "health route did not answer after restart")

        try await controller.stop(status: restarted)
        #expect(await waitForRemoval(at: paths), "runtime.json survived the final stop")
    }
}
