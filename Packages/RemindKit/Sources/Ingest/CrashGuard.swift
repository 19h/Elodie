import Foundation

/// launchd brings Remind back after a crash. If it keeps crashing, that would become a
/// loop, so after a few crashes in a row it comes back paused and says why.
public struct CrashGuard {
    public static let limit = 3
    public static let window: TimeInterval = 300

    private let defaults: UserDefaults
    private static let runningKey = "crashGuard.running"
    private static let crashesKey = "crashGuard.crashes"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Call once at launch. Returns whether this launch should stay paused.
    public func launchShouldStayPaused(now: Date = Date()) -> Bool {
        var crashes = (defaults.array(forKey: Self.crashesKey) as? [Double] ?? [])
            .filter { now.timeIntervalSince1970 - $0 < Self.window }
        // The last run never said it was finishing, so it didn't end by choice.
        if defaults.bool(forKey: Self.runningKey) {
            crashes.append(now.timeIntervalSince1970)
        }
        defaults.set(crashes, forKey: Self.crashesKey)
        defaults.set(true, forKey: Self.runningKey)
        return crashes.count >= Self.limit
    }

    /// Call after staying up for a while, which means the trouble has passed.
    public func markStable() {
        defaults.removeObject(forKey: Self.crashesKey)
    }

    /// Call when quitting normally.
    public func markCleanExit() {
        defaults.set(false, forKey: Self.runningKey)
        defaults.removeObject(forKey: Self.crashesKey)
    }
}
