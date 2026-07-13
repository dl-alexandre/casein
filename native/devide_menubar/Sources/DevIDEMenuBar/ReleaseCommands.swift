import Foundation

/// Execs the release's lifecycle scripts. The host owns the process tree but
/// launches `bin/dev_ide daemon` (which detaches), so supervision happens via
/// runtime.json's pid + the health route, not a child-process handle.
enum ReleaseCommands {
    struct CommandFailure: LocalizedError {
        var command: String
        var exitCode: Int32
        var logFile: URL?

        var errorDescription: String? {
            var message = "\(command) exited with status \(exitCode)"
            if let logFile { message += " — see \(logFile.path)" }
            return message
        }
    }

    /// Environment the host must provide, per the status contract.
    static func environment(settings: HostSettings, secrets: HostSecrets) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DEV_IDE_PROFILE"] = "desktop"
        env["DEV_IDE_DESKTOP_DATA_DIR"] = settings.dataDir.path
        env["SECRET_KEY_BASE"] = secrets.secretKeyBase
        env["DEV_IDE_API_TOKEN"] = secrets.apiToken
        env["RELEASE_NODE"] = settings.releaseNode
        env["PHX_HOST"] = "localhost"
        return env
    }

    /// Runs one release script to completion, appending stdout+stderr to a
    /// host log file so failures are inspectable from "Open Logs".
    static func run(
        script: String,
        arguments: [String] = [],
        releaseRoot: URL,
        environment: [String: String],
        logsDir: URL
    ) async throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("\(script).log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logFile)
        try logHandle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try logHandle.write(contentsOf: Data("\n===== \(stamp) \(script) \(arguments.joined(separator: " ")) =====\n".utf8))

        let process = Process()
        process.executableURL = releaseRoot.appendingPathComponent("bin/\(script)")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = releaseRoot
        process.standardOutput = logHandle
        process.standardError = logHandle

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? logHandle.close()

        guard exitCode == 0 else {
            throw CommandFailure(command: "bin/\(script) \(arguments.joined(separator: " "))", exitCode: exitCode, logFile: logFile)
        }
    }

    /// Waits until the pid from a pre-stop runtime.json exits. `bin/dev_ide
    /// stop` returns before the node has fully shut down.
    static func waitForExit(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Waits for epmd to drop the release's node name — the documented
    /// "name in use" restart race. Uses the release's own erts epmd so host
    /// and release query the same daemon. epmd not answering means nothing is
    /// registered, which also counts as drained.
    static func drainEpmd(releaseRoot: URL, nodeName: String, timeout: TimeInterval) async {
        guard let epmd = findEpmd(releaseRoot: releaseRoot) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let names = try? await capture(executable: epmd, arguments: ["-names"]) else { return }
            if !names.contains("name \(nodeName) ") { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func findEpmd(releaseRoot: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: releaseRoot.path)) ?? []
        guard let erts = contents.filter({ $0.hasPrefix("erts-") }).sorted().last else { return nil }
        let epmd = releaseRoot.appendingPathComponent("\(erts)/bin/epmd")
        return FileManager.default.isExecutableFile(atPath: epmd.path) ? epmd : nil
    }

    private static func capture(executable: URL, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
