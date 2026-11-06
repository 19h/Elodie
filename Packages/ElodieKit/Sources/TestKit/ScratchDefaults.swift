// Test support, which has no place in a release build.
#if DEBUG
import Foundation

/// Settings for one test, kept in memory. A real suite of settings is a file in
/// `~/Library/Preferences`, and the system writes those late enough that a test can't reliably
/// clean up after itself, so each run would leave more of them behind.
public enum ScratchDefaults {
    public static func make() -> UserDefaults {
        InMemoryDefaults()
    }
}

/// Every typed accessor on `UserDefaults` goes through these three.
private final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override init?(suiteName: String?) {
        super.init(suiteName: suiteName)
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}
#endif
