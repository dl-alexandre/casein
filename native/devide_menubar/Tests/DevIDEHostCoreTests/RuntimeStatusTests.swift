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
        #expect(first.secretKeyBase.count == 64)
        #expect(first.apiToken.count == 40)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions] as? Int
        #expect(permissions == 0o600)

        let second = try HostSecrets.loadOrCreate(at: url)
        #expect(first == second)
    }
}

@Suite struct HostPathsTests {
    @Test func requiresAReleaseRoot() {
        #expect(HostPaths.detect(environment: [:]) == nil)
    }

    @Test func derivesContractPathsFromEnvironment() throws {
        let paths = try #require(
            HostPaths.detect(environment: [
                "DEVIDE_RELEASE_ROOT": "/opt/devide/release",
                "DEV_IDE_DESKTOP_DATA_DIR": "/tmp/devide-data",
            ]))

        #expect(paths.statusFile.path == "/tmp/devide-data/runtime.json")
        #expect(paths.devIdeBinary.path == "/opt/devide/release/bin/dev_ide")
        #expect(paths.migrateBinary.path == "/opt/devide/release/bin/migrate")
        #expect(paths.logsDir.path == "/opt/devide/release/tmp/log")
    }

    @Test func defaultsDataDirToApplicationSupport() throws {
        let paths = try #require(
            HostPaths.detect(environment: ["DEVIDE_RELEASE_ROOT": "/opt/devide/release"]))

        #expect(paths.dataDir.path.hasSuffix("Library/Application Support/DevIDE"))
    }
}
