import CoreAPI
import CoreLive
import DesignSystem
import Foundation
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-check") {
            SelfCheck.run()
        }
        RemindApp.main()
    }
}

struct RemindApp: App {
    var body: some Scene {
        Window("Remind", id: "main") {
            Text("Remind")
                .font(.system(.largeTitle, design: .serif))
                .padding(48)
                .tint(Palette.verdigris)
        }
    }
}

/// Proves a signed build can reach the Rust core. Prints its result and exits.
enum SelfCheck {
    static func run() -> Never {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "remind-self-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let core = try LiveCore(vaultDirectory: directory, masterKey: Data(repeating: 1, count: 32))
            let info = try core.info()
            print("core \(info.version), SQLite \(info.sqliteVersion), crypto \(info.cipherProvider)")
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        } catch {
            print("self-check failed: \(error)")
            try? FileManager.default.removeItem(at: directory)
            exit(1)
        }
    }
}
