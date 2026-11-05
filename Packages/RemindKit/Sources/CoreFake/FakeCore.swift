import CoreAPI

/// `RemindCore` for previews and tests.
public struct FakeCore: RemindCore {
    public init() {}

    public func info() throws -> CoreInfo {
        CoreInfo(version: "fake", sqliteVersion: "fake", cipherProvider: "fake")
    }

    public func ping() async -> String {
        "pong"
    }
}
