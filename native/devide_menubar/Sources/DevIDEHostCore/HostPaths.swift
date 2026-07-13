import Foundation

/// Filesystem layout the host cares about: the release it supervises and the
/// data directory holding the status contract. Mirrors
/// `DevIDE.Desktop.Runtime.data_dir/0` defaults on Darwin.
public struct HostPaths: Sendable, Equatable {
    public var dataDir: URL
    public var releaseRoot: URL

    public init(dataDir: URL, releaseRoot: URL) {
        self.dataDir = dataDir
        self.releaseRoot = releaseRoot
    }

    public var statusFile: URL { dataDir.appending(path: "runtime.json") }
    /// Host-generated boot secrets (see `HostSecrets`).
    public var hostSecretsFile: URL { dataDir.appending(path: "host-secrets.json") }
    public var devIdeBinary: URL { releaseRoot.appending(path: "bin/dev_ide") }
    public var migrateBinary: URL { releaseRoot.appending(path: "bin/migrate") }
    /// run_erl daemon logs.
    public var logsDir: URL { releaseRoot.appending(path: "tmp/log") }

    /// Spike-level discovery: the release location comes from
    /// DEVIDE_RELEASE_ROOT. A packaged host will bundle or install the
    /// release and drop this requirement.
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostPaths? {
        guard let root = environment["DEVIDE_RELEASE_ROOT"], !root.isEmpty else { return nil }

        let dataDir =
            environment["DEV_IDE_DESKTOP_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/DevIDE")

        return HostPaths(dataDir: dataDir, releaseRoot: URL(filePath: root).standardizedFileURL)
    }
}
