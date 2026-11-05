import CoreABI
import CoreAPI
import Foundation

/// `RemindCore` backed by the Rust library.
public final class LiveCore: RemindCore {
    private let core: Core

    public init(vaultPath: String, key: Data) throws {
        core = try Core.open(path: vaultPath, key: key)
    }

    public func info() throws -> CoreAPI.CoreInfo {
        let info = try core.info()
        return CoreAPI.CoreInfo(
            version: info.version,
            sqliteVersion: info.sqliteVersion,
            cipherProvider: info.cipherProvider
        )
    }

    public func ping() async -> String {
        await core.ping()
    }
}
