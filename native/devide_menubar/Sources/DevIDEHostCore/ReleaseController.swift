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

    /// Distinct from the default `dev_ide` so a stray dev node or an older
    /// daemon on this machine can't collide with the hosted one.
    public static let releaseNode = "devide_desktop"

    private let paths: HostPaths

    public init(paths: HostPaths) {
        self.paths = paths
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
        try await run(paths.devIdeBinary, ["daemon"], environment: environment)
    }

    public func stop(status: RuntimeStatus?) async throws {
        phase = .stopping
        defer { phase = .idle }

        // `bin/dev_ide stop` RPCs into the node. It can fail even against a
        // live server (release rebuilds regenerate the cookie), so fall back
        // to SIGTERM on the contract pid.
        do {
            try await run(paths.devIdeBinary, ["stop"], environment: try releaseEnvironment())
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

    /// Ask the release's own epmd whether our node name is still registered.
    private func epmdListsNode() async -> Bool {
        guard let epmd = epmdBinary() else { return false }
        guard let output = try? await run(epmd, ["-names"], environment: [:]) else {
            return false
        }
        return output.contains("name \(Self.releaseNode) ")
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

    private func releaseEnvironment() throws -> [String: String] {
        let secrets = try HostSecrets.loadOrCreate(at: paths.hostSecretsFile)
        var environment = ProcessInfo.processInfo.environment
        environment["DEV_IDE_PROFILE"] = "desktop"
        environment["DEV_IDE_DESKTOP_DATA_DIR"] = paths.dataDir.path
        environment["SECRET_KEY_BASE"] = secrets.secretKeyBase
        environment["DEV_IDE_API_TOKEN"] = secrets.apiToken
        environment["PHX_SERVER"] = "true"
        environment["RELEASE_NODE"] = Self.releaseNode
        return environment
    }

    @discardableResult
    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = environment
        }
        // Release commands produce small, bounded output, so a single pipe
        // drained after exit cannot fill and deadlock.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
