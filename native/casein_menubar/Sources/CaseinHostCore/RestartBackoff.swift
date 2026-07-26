import Foundation

/// Exponential backoff for crash auto-restarts: 5s → 10s → 30s → 60s cap.
/// A quiet period (2 minutes without a crash) resets the ladder, so an
/// occasional crash recovers fast while a crash loop settles at the cap.
public struct RestartBackoff: Sendable, Equatable {
    public static let delays: [Duration] = [
        .seconds(5), .seconds(10), .seconds(30), .seconds(60),
    ]
    public static let quietPeriod: Duration = .seconds(120)

    public private(set) var consecutiveCrashes = 0
    private var lastCrashAt: ContinuousClock.Instant?

    public init() {}

    /// Record a crash and return how long to wait before restarting.
    public mutating func nextDelay(now: ContinuousClock.Instant = .now) -> Duration {
        if let last = lastCrashAt, now - last > Self.quietPeriod {
            consecutiveCrashes = 0
        }
        defer {
            lastCrashAt = now
            consecutiveCrashes += 1
        }
        return Self.delays[min(consecutiveCrashes, Self.delays.count - 1)]
    }

    /// Manual lifecycle actions reset the ladder — the operator's intent
    /// outranks crash history.
    public mutating func reset() {
        consecutiveCrashes = 0
        lastCrashAt = nil
    }
}
