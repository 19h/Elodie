import AppKit
import CoreAPI
import CoreLive
import FeatureOnboarding
import Foundation

@main
enum Entry {
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

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = AppController()
            controller?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller?.prepareToQuit()
        }
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
        MainActor.assumeIsolated { controller?.showSearch() }
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
