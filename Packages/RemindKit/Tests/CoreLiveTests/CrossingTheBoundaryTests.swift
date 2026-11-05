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

    @Test func meetingsAreRememberedInOrder() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try LiveCore(vaultDirectory: dir, masterKey: key)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try core.recordMeeting(title: "Later", from: start.addingTimeInterval(3600), to: start.addingTimeInterval(7200))
        try core.recordMeeting(title: nil, from: start, to: start.addingTimeInterval(600))

        let meetings = try core.meetings(from: start, to: start.addingTimeInterval(86_400))
        #expect(meetings.map(\.title) == [nil, "Later"])
        #expect(meetings.first?.start == start)
        #expect(meetings.first?.end == start.addingTimeInterval(600))
        #expect(try core.meetings(from: start.addingTimeInterval(86_400), to: start.addingTimeInterval(90_000)).isEmpty)
    }

    @Test func aFramesLinesComeBackWithWhereTheyAre() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = try LiveCore(vaultDirectory: dir, masterKey: key)
        let display = UUID()
        #expect(try core.append(sample(0, keyframe: true, display: display)) == .accepted)
        try core.sealAll()
        var jobs: [OCRJob] = []
        for _ in 0..<600 where jobs.isEmpty {
            jobs = try core.nextOCRBatch(max: 1, now: Date(), includeDeferred: true)
            if jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        }
        let frameID = try #require(jobs.first?.frameID)
        let rect = CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.0625)
        try core.submitOCR([OCRResult(frameID: frameID, lines: [RecognizedLine(text: "hello there", rect: rect)])])

        let lines = try core.frameLines(of: frameID)
        #expect(lines.map(\.text) == ["hello there"])
        let found = try #require(lines.first?.rect)
        #expect(abs(found.minX - rect.minX) < 0.001 && abs(found.minY - rect.minY) < 0.001)
        #expect(abs(found.width - rect.width) < 0.001 && abs(found.height - rect.height) < 0.001)
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

@Suite struct RecoveryKeys {
    private let key = Data((0..<32).map { UInt8($0 * 7 % 256) })

    @Test func aKeyComesBackFromItsText() {
        #expect(RecoveryKey.parse(RecoveryKey.text(for: key)) == key)
    }

    @Test func aSavedFileIsReadPastTheWordsAroundIt() {
        let file = """
        Remind recovery key

        \(RecoveryKey.text(for: key))

        This decrypts your recordings. Keep it somewhere safe and private.
        """
        #expect(RecoveryKey.parse(file) == key)
    }

    @Test func spacingAndCaseDontMatter() {
        let messy = RecoveryKey.text(for: key).lowercased().replacingOccurrences(of: "-", with: "  ")
        #expect(RecoveryKey.parse(messy) == key)
    }

    @Test func tooShortIsNotAKey() {
        #expect(RecoveryKey.parse("ABCDEF12-34567890") == nil)
        #expect(RecoveryKey.parse("") == nil)
        #expect(RecoveryKey.parse("this has no key in it at all") == nil)
    }

    /// Hex letters in ordinary words mustn't join up with a key or pass for one.
    @Test func wordsMadeOfHexLettersDontCount() {
        #expect(RecoveryKey.parse("a bad cafe faced a dead beef deed") == nil)
    }
}

@Suite struct OpeningAVault {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "remind-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theWrongKeyIsRefusedAndTheRightOneStillWorks() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let right = Data(repeating: 1, count: 32)
        do { _ = try LiveCore(vaultDirectory: dir, masterKey: right) }
        #expect(throws: (any Error).self) {
            _ = try LiveCore(vaultDirectory: dir, masterKey: Data(repeating: 2, count: 32))
        }
        _ = try LiveCore(vaultDirectory: dir, masterKey: right)
    }

    @Test func aSecondOpenOfTheSameVaultSaysItsBusy() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = Data(repeating: 1, count: 32)
        let first = try LiveCore(vaultDirectory: dir, masterKey: key)
        var isBusy = false
        do {
            _ = try LiveCore(vaultDirectory: dir, masterKey: key)
        } catch {
            isBusy = LiveCore.isVaultBusy(error)
        }
        #expect(isBusy)
        _ = first
    }
}
