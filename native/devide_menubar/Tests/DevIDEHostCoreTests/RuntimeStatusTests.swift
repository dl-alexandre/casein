import Foundation
import Testing

@testable import DevIDEHostCore

// Fixture: verbatim output of the first real desktop-profile boot
// (2026-07-12 smoke run), so decoding is tested against what the release
// actually writes.
private let smokeFixture = """
    {
      "base_url": "http://127.0.0.1:60682",
      "pid": 60158,
      "port": 60682,
      "revision": "6762001ce3eaa1795b27e7b4f2e4cb58e8da04a7",
      "schema": 1,
      "started_at": "2026-07-13T05:28:20.487797Z",
      "status": "ready",
      "version": "0.1.0"
    }
    """

private func temporaryFile(contents: String?) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "devide-menubar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "runtime.json")
    if let contents {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return url
}

@Suite struct RuntimeStatusTests {
    @Test func decodesTheRealContract() throws {
        let url = try temporaryFile(contents: smokeFixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let status = try RuntimeStatus.read(at: url).get()
        #expect(status.schema == 1)
        #expect(status.status == "ready")
        #expect(status.port == 60682)
        #expect(status.baseURL == URL(string: "http://127.0.0.1:60682"))
        #expect(status.pid == 60158)
        #expect(status.version == "0.1.0")
        #expect(status.revision.hasPrefix("6762001c"))
        #expect(status.startedAt.hasPrefix("2026-07-13T"))
    }

    @Test func missingFileIsTheNormalStoppedSignal() throws {
        let url = try temporaryFile(contents: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(RuntimeStatus.read(at: url) == .failure(.missing))
    }

    @Test func rejectsUnsupportedSchemas() throws {
        let url = try temporaryFile(contents: #"{"schema": 999}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(RuntimeStatus.read(at: url) == .failure(.unsupportedSchema(999)))
    }

    @Test func rejectsInvalidJSON() throws {
        let url = try temporaryFile(contents: "not json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(RuntimeStatus.read(at: url) == .failure(.invalidJSON))
    }

    @Test func staleRuleDistinguishesLiveAndDeadPids() throws {
        var status = try JSONDecoder().decode(
            RuntimeStatus.self, from: Data(smokeFixture.utf8))

        status.pid = ProcessInfo.processInfo.processIdentifier
        #expect(status.isPidAlive)

        // Spawn-and-reap a process so we hold a pid that is certainly dead.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        status.pid = process.processIdentifier
        #expect(!status.isPidAlive)
    }
}

@Suite struct HostSecretsTests {
    @Test func createsPersistsAndReloads() throws {
        let url = try temporaryFile(contents: nil)
            .deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try HostSecrets.loadOrCreate(at: url)
        // base64url: 48 bytes -> 64 chars, 32 bytes -> 43 chars (padding stripped)
        #expect(first.secretKeyBase.count == 64)
        #expect(first.apiToken.count == 43)
        #expect(!first.apiToken.contains("+") && !first.apiToken.contains("/"))

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions] as? Int
        #expect(permissions == 0o600)

        let second = try HostSecrets.loadOrCreate(at: url)
        #expect(first == second)
    }
}

@Suite struct RestartBackoffTests {
    @Test func escalatesAndCaps() {
        var backoff = RestartBackoff()
        let clock = ContinuousClock()
        let t0 = clock.now

        #expect(backoff.nextDelay(now: t0) == .seconds(5))
        #expect(backoff.nextDelay(now: t0 + .seconds(6)) == .seconds(10))
        #expect(backoff.nextDelay(now: t0 + .seconds(20)) == .seconds(30))
        #expect(backoff.nextDelay(now: t0 + .seconds(60)) == .seconds(60))
        // Capped: further crashes stay at the ceiling.
        #expect(backoff.nextDelay(now: t0 + .seconds(110)) == .seconds(60))
    }

    @Test func quietPeriodResetsTheLadder() {
        var backoff = RestartBackoff()
        let clock = ContinuousClock()
        let t0 = clock.now

        _ = backoff.nextDelay(now: t0)
        _ = backoff.nextDelay(now: t0 + .seconds(10))
        #expect(backoff.consecutiveCrashes == 2)

        // 2+ minutes of stability -> next crash starts over at 5s.
        #expect(backoff.nextDelay(now: t0 + .seconds(200)) == .seconds(5))
    }

    @Test func manualResetStartsOver() {
        var backoff = RestartBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.consecutiveCrashes == 0)
        #expect(backoff.nextDelay() == .seconds(5))
    }
}

@Suite struct LoginItemTests {
    @Test func notBundledUnderTheTestRunner() {
        // The xctest bundle is not an .app; the toggle must stay hidden in
        // this context rather than offering a register() that throws.
        #expect(!LoginItem.isBundled)
    }
}

@Suite struct HostPathsTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "devide-menubar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func requiresAReleaseRoot() throws {
        #expect(HostPaths.detect(environment: [:], defaults: try freshDefaults()) == nil)
    }

    @Test func derivesContractPathsFromEnvironment() throws {
        let paths = try #require(
            HostPaths.detect(
                environment: [
                    "DEVIDE_RELEASE_ROOT": "/opt/devide/release",
                    "DEV_IDE_DESKTOP_DATA_DIR": "/tmp/devide-data",
                ],
                defaults: try freshDefaults()))

        #expect(paths.statusFile.path == "/tmp/devide-data/runtime.json")
        #expect(paths.devIdeBinary.path == "/opt/devide/release/bin/dev_ide")
        #expect(paths.migrateBinary.path == "/opt/devide/release/bin/migrate")
        #expect(paths.logsDir.path == "/opt/devide/release/tmp/log")
    }

    @Test func defaultsDataDirToApplicationSupport() throws {
        let paths = try #require(
            HostPaths.detect(
                environment: ["DEVIDE_RELEASE_ROOT": "/opt/devide/release"],
                defaults: try freshDefaults()))

        #expect(paths.dataDir.path.hasSuffix("Library/Application Support/DevIDE"))
    }

    @Test func environmentOutranksPersistedChoice() throws {
        let defaults = try freshDefaults()
        defaults.set("/persisted/release", forKey: HostPaths.releaseRootDefaultsKey)

        let persisted = try #require(HostPaths.detect(environment: [:], defaults: defaults))
        #expect(persisted.releaseRoot.path == "/persisted/release")

        let overridden = try #require(
            HostPaths.detect(
                environment: ["DEVIDE_RELEASE_ROOT": "/env/release"], defaults: defaults))
        #expect(overridden.releaseRoot.path == "/env/release")
    }

    @Test func chooseRejectsDirectoriesWithoutARelease() throws {
        let defaults = try freshDefaults()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "not-a-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(HostPaths.choose(releaseRoot: dir, defaults: defaults) == nil)
        #expect(defaults.string(forKey: HostPaths.releaseRootDefaultsKey) == nil)
    }

    @Test func choosePersistsAUsableRelease() throws {
        let defaults = try freshDefaults()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fake-release-\(UUID().uuidString)")
        let bin = dir.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let devIde = bin.appending(path: "dev_ide")
        try "#!/bin/sh\n".write(to: devIde, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: devIde.path)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths = try #require(HostPaths.choose(releaseRoot: dir, defaults: defaults))
        #expect(paths.releaseRoot.path == dir.standardizedFileURL.path)
        #expect(defaults.string(forKey: HostPaths.releaseRootDefaultsKey) != nil)
    }
}
