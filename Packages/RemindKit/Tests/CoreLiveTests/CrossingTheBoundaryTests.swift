import CoreAPI
import CoreFake
import CoreLive
import Foundation
import Testing

@Suite struct CrossingTheBoundary {
    private func temporaryVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "remind-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func syncCallsReachRust() throws {
        let dir = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = try LiveCore(
            vaultPath: dir.appending(path: "vault.db").path,
            key: Data(repeating: 7, count: 32)
        )
        let info = try core.info()
        #expect(info.cipherProvider == "commoncrypto")
        #expect(!info.version.isEmpty)
    }

    @Test func asyncCallsReachRust() async throws {
        let dir = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let core = try LiveCore(
            vaultPath: dir.appending(path: "vault.db").path,
            key: Data(repeating: 7, count: 32)
        )
        #expect(await core.ping() == "pong")
    }

    @Test func rustErrorsBecomeSwiftErrors() throws {
        let dir = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: (any Error).self) {
            try LiveCore(vaultPath: dir.appending(path: "vault.db").path, key: Data([1, 2, 3]))
        }
    }

    @Test func theFakeSatisfiesTheSameProtocol() async throws {
        let core: any RemindCore = FakeCore()
        #expect(await core.ping() == "pong")
    }
}
