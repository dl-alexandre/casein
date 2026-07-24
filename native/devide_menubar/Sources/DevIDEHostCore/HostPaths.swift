import Foundation

/// Filesystem layout the host cares about: the release it supervises and the
/// data directory holding the status contract. Mirrors
/// `Casein.Desktop.Runtime.data_dir/0` defaults on Darwin.
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
    public var hostSettingsFile: URL { dataDir.appending(path: "desktop-host.json") }
    public var devIdeBinary: URL { releaseRoot.appending(path: "bin/casein") }
    public var migrateBinary: URL { releaseRoot.appending(path: "bin/migrate") }
    /// Writable release runtime state. Keeping this outside the signed app
    /// bundle prevents run_erl logs from invalidating its code signature.
    public var runtimeDir: URL { dataDir.appending(path: "runtime") }
    public var logsDir: URL { runtimeDir.appending(path: "log") }

    static let releaseRootDefaultsKey = "releaseRoot"

    /// Release discovery: an explicit environment override wins, followed by
    /// the release embedded in the application bundle and finally a persisted
    /// developer-selected release.
    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        bundleResources: URL? = Bundle.main.resourceURL
    ) -> HostPaths? {
        let bundledRoot = bundleResources?.appending(path: "release")
        let usableBundledRoot = bundledRoot.flatMap { root in
            FileManager.default.isExecutableFile(atPath: root.appending(path: "bin/casein").path)
                ? root.path : nil
        }
        let root =
            environment["DEVIDE_RELEASE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? usableBundledRoot
            ?? defaults.string(forKey: releaseRootDefaultsKey)
        guard let root, !root.isEmpty else { return nil }

        let dataDir =
            environment["CASEIN_DESKTOP_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? defaultDataDir()

        return HostPaths(dataDir: dataDir, releaseRoot: URL(filePath: root).standardizedFileURL)
    }

    static func defaultDataDir(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = home.appending(path: "Library/Application Support")
        let current = applicationSupport.appending(path: "Casein")
        let legacy = applicationSupport.appending(path: "DevIDE")

        // Existing installs keep their data and Keychain account path. Fresh
        // installs use the Casein product identity.
        if !fileManager.fileExists(atPath: current.path),
           fileManager.fileExists(atPath: legacy.path)
        {
            return legacy
        }

        return current
    }

    /// Persist an operator-chosen release directory and return the resulting
    /// paths. Returns nil if the directory is not a usable release
    /// (`bin/casein` missing).
    public static func choose(
        releaseRoot: URL,
        defaults: UserDefaults = .standard
    ) -> HostPaths? {
        let candidate = releaseRoot.standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: candidate.appending(path: "bin/casein").path)
        else { return nil }
        defaults.set(candidate.path, forKey: releaseRootDefaultsKey)
        return detect(defaults: defaults)
    }
}
