import DevIDEHostCore
import Foundation

/// Headless exerciser for the host core — the same calls the menu buttons
/// make, with timings printed for smoke verification.
@main
struct HostCLI {
    static func main() async {
        guard let paths = HostPaths.detect() else {
            fputs("error: DEVIDE_RELEASE_ROOT not set and no persisted choice\n", stderr)
            exit(2)
        }
        let controller = ReleaseController(paths: paths)
        let command = CommandLine.arguments.dropFirst().first ?? "status"

        do {
            switch command {
            case "status":
                await printStatus(paths: paths)
            case "start":
                let clock = ContinuousClock()
                let t0 = clock.now
                try await controller.start()
                print("daemon command returned after \(clock.now - t0)")
                try await waitHealthy(paths: paths, since: t0, clock: clock)
            case "stop":
                let status = try? RuntimeStatus.read(at: paths.statusFile).get()
                let clock = ContinuousClock()
                let t0 = clock.now
                try await controller.stop(status: status)
                let gone = !FileManager.default.fileExists(atPath: paths.statusFile.path)
                print("stopped after \(clock.now - t0); contract removed=\(gone)")
            case "restart":
                let status = try? RuntimeStatus.read(at: paths.statusFile).get()
                let clock = ContinuousClock()
                let t0 = clock.now
                try await controller.restart(status: status)
                print("restart command chain returned after \(clock.now - t0)")
                try await waitHealthy(paths: paths, since: t0, clock: clock)
            default:
                fputs("usage: devide-host-cli [status|start|stop|restart]\n", stderr)
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printStatus(paths: HostPaths) async {
        switch RuntimeStatus.read(at: paths.statusFile) {
        case .success(let status):
            print(
                "contract: status=\(status.status) port=\(status.port) pid=\(status.pid)",
                "alive=\(status.isPidAlive) version=\(status.version)")
            if let health = await HealthProbe.probe(baseURL: status.baseURL) {
                print("health: \(health.status) uptime_ms=\(health.uptimeMs ?? -1)")
            } else {
                print("health: unreachable (monitor state would be: unhealthy)")
            }
        case .failure(let reason):
            print("no contract (\(reason)) — monitor state would be: stopped")
        }
    }

    static func waitHealthy(
        paths: HostPaths, since t0: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws {
        var sawContract = false
        while true {
            if case .success(let status) = RuntimeStatus.read(at: paths.statusFile) {
                if !sawContract {
                    sawContract = true
                    print(
                        "runtime.json after \(clock.now - t0):",
                        "port=\(status.port) pid=\(status.pid)")
                }
                if let health = await HealthProbe.probe(baseURL: status.baseURL, timeout: 1) {
                    print(
                        "healthy after \(clock.now - t0):",
                        "\(health.status) uptime_ms=\(health.uptimeMs ?? -1)")
                    return
                }
            }
            if clock.now - t0 > .seconds(90) {
                fputs("error: not healthy within 90s\n", stderr)
                exit(1)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
