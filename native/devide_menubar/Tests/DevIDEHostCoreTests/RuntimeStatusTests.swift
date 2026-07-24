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

private final class MemoryHostSecretStore: HostSecretStore, @unchecked Sendable {
    enum StoreError: Error { case saveFailed }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private let failSave: Bool

    init(failSave: Bool = false) {
        self.failSave = failSave
    }

    func load(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func save(_ data: Data, account: String) throws {
        if failSave { throw StoreError.saveFailed }
        lock.withLock { items[account] = data }
    }

    func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
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
    @Test func keychainRoundTripUsesDataDirectoryAccount() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer {
            try? HostSecrets.deleteFromKeychain(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let first = try HostSecrets.loadOrCreate(at: url)
        let second = try HostSecrets.loadOrCreate(at: url)

        #expect(first == second)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func createsPersistsAndReloads() throws {
        let url = try temporaryFile(contents: nil)
            .deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = MemoryHostSecretStore()
        let first = try HostSecrets.loadOrCreate(at: url, store: store)
        // base64url: 48 bytes -> 64 chars, 32 bytes -> 43 chars (padding stripped)
        #expect(first.secretKeyBase.count == 64)
        #expect(first.apiToken.count == 43)
        #expect(first.desktopLaunchToken.count == 43)
        #expect(!first.apiToken.contains("+") && !first.apiToken.contains("/"))

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let second = try HostSecrets.loadOrCreate(at: url, store: store)
        #expect(first == second)
    }

    @Test func migratesLegacySecretsWithoutRotatingExistingValues() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacySecret = String(repeating: "s", count: 64)
        let legacyAPI = String(repeating: "a", count: 43)
        try "{\"secret_key_base\":\"\(legacySecret)\",\"api_token\":\"\(legacyAPI)\"}"
            .write(to: url, atomically: true, encoding: .utf8)

        let store = MemoryHostSecretStore()
        let migrated = try HostSecrets.loadOrCreate(at: url, store: store)
        #expect(migrated.secretKeyBase == legacySecret)
        #expect(migrated.apiToken == legacyAPI)
        #expect(migrated.desktopLaunchToken.count == 43)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try HostSecrets.loadOrCreate(at: url, store: store) == migrated)
    }

    @Test func upgradesOldKeychainSchemaOnlyOnce() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let account = HostSecrets.keychainAccount(for: url)
        let store = MemoryHostSecretStore()
        let legacySecret = String(repeating: "s", count: 64)
        let legacyAPI = String(repeating: "a", count: 43)
        try store.save(
            Data("{\"secret_key_base\":\"\(legacySecret)\",\"api_token\":\"\(legacyAPI)\"}".utf8),
            account: account)

        let first = try HostSecrets.loadOrCreate(at: url, store: store)
        let second = try HostSecrets.loadOrCreate(at: url, store: store)

        #expect(first == second)
        #expect(first.desktopLaunchToken.count == 43)
    }

    @Test func upgradesNullLaunchTokenOnlyOnce() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let account = HostSecrets.keychainAccount(for: url)
        let store = MemoryHostSecretStore()
        let legacySecret = String(repeating: "s", count: 64)
        let legacyAPI = String(repeating: "a", count: 43)
        try store.save(
            Data("{\"secret_key_base\":\"\(legacySecret)\",\"api_token\":\"\(legacyAPI)\",\"desktop_launch_token\":null}".utf8),
            account: account)

        let first = try HostSecrets.loadOrCreate(at: url, store: store)
        let second = try HostSecrets.loadOrCreate(at: url, store: store)

        #expect(first == second)
        #expect(first.desktopLaunchToken.count == 43)
    }

    @Test func failedKeychainMigrationPreservesLegacyFile() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacySecret = String(repeating: "s", count: 64)
        let legacyAPI = String(repeating: "a", count: 43)
        try "{\"secret_key_base\":\"\(legacySecret)\",\"api_token\":\"\(legacyAPI)\"}"
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: MemoryHostSecretStore.StoreError.saveFailed) {
            try HostSecrets.loadOrCreate(at: url, store: MemoryHostSecretStore(failSave: true))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func malformedKeychainPayloadFailsClosed() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MemoryHostSecretStore()
        try store.save(Data("not-json".utf8), account: HostSecrets.keychainAccount(for: url))

        #expect(throws: (any Error).self) { try HostSecrets.loadOrCreate(at: url, store: store) }
    }

    @Test func malformedExistingSecretsFailClosed() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "not-json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try HostSecrets.loadOrCreate(at: url, store: MemoryHostSecretStore())
        }
    }

    @Test func syntacticallyValidWeakSecretsFailClosed() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "host-secrets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #"{"secret_key_base":"short","api_token":"","desktop_launch_token":"short"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) {
            try HostSecrets.loadOrCreate(at: url, store: MemoryHostSecretStore())
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func secretSymlinksFailClosedWithoutChangingTheirTarget() throws {
        let directory = try temporaryFile(contents: nil).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.json")
        let link = directory.appending(path: "host-secrets.json")
        try "protected".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try HostSecrets.loadOrCreate(at: link, store: MemoryHostSecretStore())
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(permissions == 0o644)
    }
}

@Suite struct DesktopLaunchTests {
    @Test func settingsSelectAndPersistAValidLoopbackPort() throws {
        let url = try temporaryFile(contents: nil).deletingLastPathComponent()
            .appending(path: "desktop-host.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalPermissions = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        let first = try HostSettings.loadOrSelect(at: url)
        #expect((1024...65535).contains(first.port))
        #expect(try HostSettings.loadOrSelect(at: url) == first)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(directoryPermissions == originalPermissions)
    }

    @Test func cockpitURLIsCanonicalAndAuthenticated() async throws {
        let dataDir = try temporaryFile(contents: nil).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let paths = HostPaths(dataDir: dataDir, releaseRoot: dataDir)
        let launchToken = String(repeating: "l", count: 43)
        let secrets = HostSecrets(
            secretKeyBase: String(repeating: "s", count: 64),
            apiToken: String(repeating: "a", count: 43),
            desktopLaunchToken: launchToken)
        let store = MemoryHostSecretStore()
        try store.save(JSONEncoder().encode(secrets), account: HostSecrets.keychainAccount(for: paths.hostSecretsFile))
        let controller = ReleaseController(paths: paths, secretStore: store)
        var status = try JSONDecoder().decode(RuntimeStatus.self, from: Data(smokeFixture.utf8))
        status.baseURL = URL(string: "https://attacker.example/steal")!

        let url = try await controller.cockpitURL(for: status)
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == status.port)
        let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        #expect(query["desktop_nonce"]?.count == 22)
        #expect(Int64(query["desktop_timestamp"] ?? "") != nil)
        #expect(query["desktop_proof"]?.count == 43)
        #expect(!url.absoluteString.contains(launchToken))
        let clean = try await controller.cleanCockpitURL(for: status).url
        #expect(clean?.absoluteString == "http://127.0.0.1:\(status.port)/")
    }

    @Test func finderLikeEnvironmentRepairsShellAndToolPath() async throws {
        let dataDir = try temporaryFile(contents: nil).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let controller = ReleaseController(
            paths: HostPaths(dataDir: dataDir, releaseRoot: dataDir),
            inheritedEnvironment: ["HOME": dataDir.path, "PATH": "/usr/bin:/bin"],
            secretStore: MemoryHostSecretStore())
        let environment = try await controller.releaseEnvironment()
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin") == true)
        #expect(environment["RELEASE_TMP"] == dataDir.appending(path: "runtime").path)
    }

    @Test func rejectsSharedWritableDataDirectoryWithoutChmoddingIt() throws {
        let directory = try temporaryFile(contents: nil).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let settings = directory.appending(path: "desktop-host.json")

        #expect(throws: (any Error).self) { try HostSettings.loadOrSelect(at: settings) }
        let permissions = try FileManager.default.attributesOfItem(
            atPath: directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o777)
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
        #expect(HostPaths.detect(environment: [:], defaults: try freshDefaults(), bundleResources: nil) == nil)
    }

    @Test func derivesContractPathsFromEnvironment() throws {
        let paths = try #require(
            HostPaths.detect(
                environment: [
                    "DEVIDE_RELEASE_ROOT": "/opt/devide/release",
                    "CASEIN_DESKTOP_DATA_DIR": "/tmp/devide-data",
                ],
                defaults: try freshDefaults(), bundleResources: nil))

        #expect(paths.statusFile.path == "/tmp/devide-data/runtime.json")
        #expect(paths.devIdeBinary.path == "/opt/devide/release/bin/casein")
        #expect(paths.migrateBinary.path == "/opt/devide/release/bin/migrate")
        #expect(paths.logsDir.path == "/tmp/devide-data/runtime/log")
    }

    @Test func defaultsDataDirToApplicationSupport() throws {
        let paths = try #require(
            HostPaths.detect(
                environment: ["DEVIDE_RELEASE_ROOT": "/opt/devide/release"],
                defaults: try freshDefaults(), bundleResources: nil))

        #expect(paths.dataDir.path.hasSuffix("Library/Application Support/DevIDE"))
    }

    @Test func environmentOutranksPersistedChoice() throws {
        let defaults = try freshDefaults()
        defaults.set("/persisted/release", forKey: HostPaths.releaseRootDefaultsKey)

        let persisted = try #require(
            HostPaths.detect(environment: [:], defaults: defaults, bundleResources: nil))
        #expect(persisted.releaseRoot.path == "/persisted/release")

        let overridden = try #require(
            HostPaths.detect(
                environment: ["DEVIDE_RELEASE_ROOT": "/env/release"], defaults: defaults,
                bundleResources: nil))
        #expect(overridden.releaseRoot.path == "/env/release")
    }

    @Test func embeddedReleaseOutranksPersistedChoice() throws {
        let defaults = try freshDefaults()
        defaults.set("/persisted/release", forKey: HostPaths.releaseRootDefaultsKey)
        let resources = FileManager.default.temporaryDirectory
            .appending(path: "devide-bundle-\(UUID().uuidString)")
        let releaseBin = resources.appending(path: "release/bin")
        try FileManager.default.createDirectory(at: releaseBin, withIntermediateDirectories: true)
        let executable = releaseBin.appending(path: "dev_ide")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: resources) }

        let paths = try #require(
            HostPaths.detect(environment: [:], defaults: defaults, bundleResources: resources))
        #expect(paths.releaseRoot.path == resources.appending(path: "release").path)
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
