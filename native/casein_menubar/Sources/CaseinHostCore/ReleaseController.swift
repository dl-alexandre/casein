import Foundation

/// Owns the release process lifecycle. The host stays dumb: it execs the
/// release binaries, reads the published contract, and never speaks BEAM.
///
/// Restart implements the documented sequence: graceful stop, wait for the
/// process to exit, wait for epmd to drop the node name (the "name in use"
/// trap), migrate, start fresh.
public actor ReleaseController {
    public enum Phase: Sendable, Equatable { case idle, starting, stopping }

    public private(set) var phase: Phase = .idle

    /// Distinct from the default `casein` so a stray dev node or an older
    /// daemon on this machine can't collide with the hosted one.
    public static let defaultReleaseNode = "casein_desktop"

    private let paths: HostPaths
    private let releaseNode: String
    private let inheritedEnvironment: [String: String]
    private let secretStore: any HostSecretStore
    private var selectedPort: Int?

    /// `releaseNode` is injectable so parallel test suites (or a second
    /// host instance) can boot isolated nodes; the app always uses the
    /// default.
    public init(
        paths: HostPaths,
        releaseNode: String = ReleaseController.defaultReleaseNode,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        secretStore: any HostSecretStore = KeychainSecretStore()
    ) {
        self.paths = paths
        self.releaseNode = releaseNode
        self.inheritedEnvironment = inheritedEnvironment
        self.secretStore = secretStore
    }

    public struct CommandError: Error, CustomStringConvertible {
        public let command: String
        public let exitCode: Int32
        public let output: String

        public var description: String {
            "\(command) exited \(exitCode): \(output.suffix(300))"
        }
    }

    public func start() async throws {
        phase = .starting
        defer { phase = .idle }

        let environment = try releaseEnvironment()
        try await run(paths.migrateBinary, [], environment: environment)
        do {
            try await run(paths.caseinBinary, ["daemon"], environment: environment)
        } catch {
            // Port allocation is a bind-and-close handoff. Retry once with a
            // fresh probe in case another process won that narrow race.
            selectedPort = nil
            let retryEnvironment = try releaseEnvironment()
            do {
                try await run(paths.caseinBinary, ["daemon"], environment: retryEnvironment)
            } catch {
                selectedPort = nil
                throw error
            }
        }
    }

    public func stop(status: RuntimeStatus?) async throws {
        phase = .stopping
        defer { phase = .idle }

        if let port = status?.port, (1024...65535).contains(port) {
            // A recreated menu host may attach to a daemon it left running.
            // Its live port is owned by us even though a generic availability
            // probe necessarily sees it as occupied.
            selectedPort = port
        }

        // `bin/casein stop` RPCs into the node. It can fail even against a
        // live server (release rebuilds regenerate the cookie), so fall back
        // to SIGTERM on the contract pid.
        do {
            try await run(paths.caseinBinary, ["stop"], environment: try releaseEnvironment())
        } catch {
            if let pid = status?.pid, kill(pid, 0) == 0 {
                kill(pid, SIGTERM)
            }
        }

        if let pid = status?.pid {
            try await wait(timeout: .seconds(15), for: "process \(pid) to exit") {
                kill(pid, 0) != 0
            }
        }
    }

    public func restart(status: RuntimeStatus?) async throws {
        try await stop(status: status)
        // Best-effort: if epmd is unreachable the start attempt itself will
        // surface the name collision.
        try? await wait(timeout: .seconds(30), for: "epmd to drop the node name") {
            await !self.epmdListsNode()
        }
        try await start()
    }

    public func cockpitURL(for status: RuntimeStatus) throws -> URL {
        let secrets = try HostSecrets.loadOrCreate(at: paths.hostSecretsFile, store: secretStore)
        var components = try cleanCockpitURL(for: status)
        components.queryItems = try DesktopLaunchClaim.queryItems(secret: secrets.desktopLaunchToken)
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    public func cleanCockpitURL(for status: RuntimeStatus) throws -> URLComponents {
        guard (1024...65535).contains(status.port) else { throw URLError(.badURL) }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = status.port
        components.path = "/"
        guard components.url != nil else { throw URLError(.badURL) }
        return components
    }

    public func lanEnabled() -> Bool {
        HostSettings.load(at: paths.hostSettingsFile)?.lanEnabled ?? false
    }

    public func setLANEnabled(_ enabled: Bool) throws {
        if enabled, LANConfiguration.detect() == nil {
            throw CommandError(
                command: "enable LAN",
                exitCode: -1,
                output: "no active private IPv4 network was found"
            )
        }
        try HostSettings.setLANEnabled(enabled, at: paths.hostSettingsFile)
    }

    public func lanURL(for status: RuntimeStatus) -> URL? {
        guard lanEnabled(), let configuration = LANConfiguration.detect() else { return nil }
        return configuration.url(port: status.port)
    }

    public func lanCockpitURL(for status: RuntimeStatus) throws -> URL {
        guard let url = lanURL(for: status),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw URLError(.badURL)
        }

        let secrets = try HostSecrets.loadOrCreate(at: paths.hostSecretsFile, store: secretStore)
        components.queryItems = try DesktopLaunchClaim.queryItems(secret: secrets.desktopLaunchToken)
        guard let authenticatedURL = components.url else { throw URLError(.badURL) }
        return authenticatedURL
    }

    /// Ask the release's own epmd whether our node name is still registered.
    private func epmdListsNode() async -> Bool {
        guard let epmd = epmdBinary() else { return false }
        guard let output = try? await run(epmd, ["-names"], environment: [:]) else {
            return false
        }
        return output.contains("name \(releaseNode) ")
    }

    private func epmdBinary() -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(atPath: paths.releaseRoot.path),
            let erts = entries.first(where: { $0.hasPrefix("erts-") })
        else { return nil }
        let epmd = paths.releaseRoot.appending(path: "\(erts)/bin/epmd")
        return fm.isExecutableFile(atPath: epmd.path) ? epmd : nil
    }

    func releaseEnvironment() throws -> [String: String] {
        let secrets = try HostSecrets.loadOrCreate(at: paths.hostSecretsFile, store: secretStore)
        // The host's own environment must not reconfigure the release: an
        // inherited PORT would defeat the ephemeral-port design, a stray
        // PHX_IP would fail the loopback guard, and DATABASE_PATH or a
        // status-path override would detach the contract from the data dir.
        // Allowlist rather than denylist so the next release-reconfiguring
        // var (MIX_ENV, CASEIN_LAN, …) is excluded by default instead of
        // needing a new scrub entry. PATH passes through for tmux/git.
        let inherited = inheritedEnvironment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "TMPDIR"] {
            environment[key] = inherited[key]
        }
        environment["SHELL"] = inherited["SHELL"] ?? "/bin/zsh"
        environment["PATH"] = hostPath(inherited["PATH"])
        environment["LANG"] = inherited["LANG"] ?? "en_US.UTF-8"
        environment["LC_ALL"] = inherited["LC_ALL"] ?? "en_US.UTF-8"
        environment["CASEIN_PROFILE"] = "desktop"
        environment["CASEIN_RELEASE_ROOT"] = paths.releaseRoot.path
        environment["CASEIN_DESKTOP_DATA_DIR"] = paths.dataDir.path
        environment["RELEASE_TMP"] = paths.runtimeDir.path
        environment["SECRET_KEY_BASE"] = secrets.secretKeyBase
        environment["CASEIN_API_TOKEN"] = secrets.apiToken
        environment["CASEIN_DESKTOP_LAUNCH_TOKEN"] = secrets.desktopLaunchToken
        let settings: HostSettings
        let port: Int
        if let selectedPort {
            port = selectedPort
            settings = HostSettings.load(at: paths.hostSettingsFile)
                ?? HostSettings(port: port)
        } else {
            settings = try HostSettings.loadOrSelect(at: paths.hostSettingsFile)
            port = settings.port
            selectedPort = port
        }
        environment["PORT"] = String(port)
        environment["PHX_SERVER"] = "true"
        environment["RELEASE_NODE"] = releaseNode

        if settings.lanEnabled {
            guard let lan = LANConfiguration.detect() else {
                throw CommandError(
                    command: "start LAN",
                    exitCode: -1,
                    output: "no active private IPv4 network was found"
                )
            }
            environment["CASEIN_DESKTOP_LAN"] = "true"
            environment["CASEIN_LAN_INSECURE_HTTP"] = "true"
            environment["CASEIN_LAN_HOST"] = lan.host
            environment["CASEIN_LAN_IP"] = lan.ip
            environment["CASEIN_LAN_IPS"] = lan.ips.joined(separator: ",")
            environment["PHX_IP"] = "0.0.0.0"
        }
        return environment
    }

    private func hostPath(_ inherited: String?) -> String {
        let baseline = inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        return (["/opt/homebrew/bin", "/usr/local/bin"] + baseline.split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    @discardableResult
    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let commandOutputDirectory = paths.runtimeDir.appending(path: "commands", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: commandOutputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outputURL = commandOutputDirectory.appending(path: "\(UUID().uuidString).log")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = environment
        }
        // A regular file cannot fill like an undrained pipe. Read only its
        // tail after exit so a noisy failed command cannot consume unbounded
        // memory or deadlock the menu host.
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        try outputHandle.synchronize()
        let readHandle = try FileHandle(forReadingFrom: outputURL)
        defer { try? readHandle.close() }
        let length = try readHandle.seekToEnd()
        let maximumOutputBytes: UInt64 = 64 * 1024
        try readHandle.seek(toOffset: length > maximumOutputBytes ? length - maximumOutputBytes : 0)
        let data = try readHandle.readToEnd() ?? Data()
        let output = String(decoding: data, as: UTF8.self)

        guard exitCode == 0 else {
            throw CommandError(
                command: executable.lastPathComponent,
                exitCode: exitCode,
                output: output
            )
        }
        return output
    }

    private func wait(
        timeout: Duration,
        for what: String,
        until condition: @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CommandError(command: "wait", exitCode: -1, output: "timed out waiting for \(what)")
    }
}
