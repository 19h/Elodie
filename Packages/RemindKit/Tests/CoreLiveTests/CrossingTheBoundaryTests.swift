import CoreAPI
import CoreFake
import CoreLive
import Foundation
import Testing

@Suite struct CrossingTheBoundary {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "remind-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let key = Data(repeating: 7, count: 32)

    private func sample(_ n: Int, keyframe: Bool, display: UUID) -> EncodedSample {
        EncodedSample(
            displayID: display,
            width: 100,
            height: 50,
            parameterSets: Data("params".utf8),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 2),
            monotonicNanoseconds: UInt64(n),
            isKeyframe: keyframe,
            context: FrameContext(bundleID: "com.example", window: "Wörk 東京"),
            data: Data(repeating: UInt8(n), count: 64)
        )
    }

    @Test func rustIsReachable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try LiveCore(vaultDirectory: dir, masterKey: key).info()
        #expect(info.cipherProvider == "commoncrypto")
    }

    @Test func aBadKeyBecomesASwiftError() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try LiveCore(vaultDirectory: dir, masterKey: Data([1, 2, 3]))
        }
    }

    /// The whole write and read path, through real files, across FFI.
    @Test func samplesRoundTripAcrossABoundaryAndARelaunch() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let display = UUID()

        var core: LiveCore? = try LiveCore(vaultDirectory: dir, masterKey: key)
        for n in 0..<5 {
            // Paced, because the queue holds only 8 and appends here are instant.
            #expect(try core!.append(sample(n, keyframe: n == 0, display: display)) == .accepted)
            try await Task.sleep(for: .milliseconds(20))
        }
        try core!.sealAll()
        core = nil

        core = try LiveCore(vaultDirectory: dir, masterKey: key)
        let time = Date(timeIntervalSince1970: 1_800_000_000 + 6.5)
        let frame = try #require(try core!.lookup(display: display, at: time))
        #expect(frame.capturedAt == Date(timeIntervalSince1970: 1_800_000_006))

        let group = try core!.readGroup(containing: frame.id)
        #expect(group.samples.count == 5)
        #expect(group.target == 3)
        #expect(group.samples[3].data == Data(repeating: 3, count: 64))
        #expect(group.parameterSets == Data("params".utf8))
        #expect(group.width == 100)
    }

    @Test func nonKeyframesAreRefusedAtTheStart() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try LiveCore(vaultDirectory: dir, masterKey: key)
        #expect(try core.append(sample(0, keyframe: false, display: UUID())) == .needsKeyframe)
    }

    @Test func theFakeSatisfiesTheSameContract() throws {
        let core: any RemindCore = FakeCore()
        let display = UUID()
        for n in 0..<5 {
            _ = try core.append(sample(n, keyframe: n % 3 == 0, display: display))
        }
        let frame = try #require(try core.lookup(display: display, at: Date(timeIntervalSince1970: 1_800_000_008)))
        let group = try core.readGroup(containing: frame.id)
        #expect(group.samples.count == 2)
        #expect(group.target == 1)
    }
}
