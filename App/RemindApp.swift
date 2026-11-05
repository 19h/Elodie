import AppKit
import CoreAPI
import CoreLive
import FeatureOnboarding
import Foundation
import os

@main
enum Entry {
    /// Passed by a copy of Remind that's reopening itself.
    static let relaunchedArgument = "--relaunched"

    /// Only one copy can record. The login item starts Remind as soon as it's turned on, while
    /// the copy that turned it on is still running, and a second one would fight it for the
    /// vault. So a later copy hands over to the first and leaves.
    private static func leaveIfAlreadyRunning(arguments: [String]) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
            }
        }
        if arguments.contains(relaunchedArgument) {
            // The copy that started this one is on its way out.
            for _ in 0..<100 where !others().isEmpty {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if let running = others().first {
            running.activate()
            exit(0)
        }
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains(PermissionMonitor.checkArgument) {
            // A new process's view of the Screen Recording grant. See PermissionMonitor.
            exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
        }
        if arguments.contains("--self-check") {
            SelfCheck.run()
        }
        #if DEBUG
        if arguments.contains("--spike") {
            MainActor.assumeIsolated { LiveSpikes.run(arguments: arguments) }
        }
        if arguments.contains("--scenario") {
            MainActor.assumeIsolated { Scenarios.run(arguments: arguments) }
        }
        #endif

        #if DEBUG
        if let flag = arguments.firstIndex(of: "--sandbox"), arguments.indices.contains(flag + 1) {
            AppEnvironment.sandbox = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
            KeyStore.service = "app.remind.vault.sandbox"
        } else {
            leaveIfAlreadyRunning(arguments: arguments)
        }
        #else
        leaveIfAlreadyRunning(arguments: arguments)
        #endif

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

// Only the lock is touched away from the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = AppController()
            controller?.start()
        }
    }

    /// The longest quitting waits for anything.
    private static let quitDeadline: TimeInterval = 5
    private let quitReply = OSAllocatedUnfairLock(initialState: false)

    /// What's being said right now only becomes words when it's told to finish, so quitting
    /// waits briefly for that. Everything recorded so far reaches the drive first too.
    ///
    /// After this returns, AppKit runs its own loop until it gets an answer. When something
    /// quits from an async function, that loop is inside a job on the main actor, so nothing
    /// else on the main actor or main queue can run until it ends. So nothing here waits for
    /// them: the work runs elsewhere, and the answer comes back through the run loop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let finish = controller?.prepareToQuit() else { return .terminateNow }
            let answer: @Sendable () -> Void = { [self] in
                let isFirst = quitReply.withLock { answered in
                    defer { answered = true }
                    return !answered
                }
                guard isFirst else { return }
                performSelector(
                    onMainThread: #selector(allowTermination),
                    with: nil,
                    waitUntilDone: false,
                    modes: [RunLoop.Mode.modalPanel.rawValue, RunLoop.Mode.default.rawValue]
                )
            }
            Task.detached(priority: .userInitiated) {
                await finish()
                answer()
            }
            // Whatever happens to that work, quitting can't be held up by it for long.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.quitDeadline, execute: answer)
            return .terminateLater
        }
    }

    @objc private func allowTermination() {
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `remind://moment/<milliseconds>` opens the timeline at that moment.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let time = DeepLink.time(from: url) {
                    controller?.showMoment(at: time)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { controller?.handleReopen() }
        return false
    }
}

/// Links to moments, as in `remind://moment/1800000000000`.
enum DeepLink {
    static func url(for time: Date) -> URL {
        URL(string: "remind://moment/\(Int64(time.timeIntervalSince1970 * 1000))")!
    }

    /// Reads a moment link. These come from outside the app, so anything malformed gives
    /// `nil`, and a link can only say where to look.
    static func time(from url: URL) -> Date? {
        guard url.scheme == "remind", url.host() == "moment",
              let milliseconds = Int64(url.lastPathComponent),
              milliseconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

/// Proves a signed build can reach the Rust core. Prints its result and exits.
enum SelfCheck {
    static func run() -> Never {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-self-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var core: LiveCore? = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 1, count: 32))
            let info = try core!.info()
            print("core \(info.version), SQLite \(info.sqliteVersion), crypto \(info.cipherProvider)")
            core = nil
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        } catch {
            print("self-check failed: \(error)")
            try? FileManager.default.removeItem(at: directory)
            exit(1)
        }
    }
}
