/// What the running core was built with.
public struct CoreInfo: Sendable, Equatable {
    public var version: String
    public var sqliteVersion: String
    public var cipherProvider: String

    public init(version: String, sqliteVersion: String, cipherProvider: String) {
        self.version = version
        self.sqliteVersion = sqliteVersion
        self.cipherProvider = cipherProvider
    }
}

/// The app's view of the Rust core.
///
/// Feature code depends on this protocol and never on the generated bindings,
/// so previews and tests can run against `FakeCore` with no vault or screen.
public protocol RemindCore: Sendable {
    func info() throws -> CoreInfo
    func ping() async -> String
}
