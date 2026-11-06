import AppKit
import Sparkle

/// Checks for and installs updates. This is the only part of Elodie that uses the
/// network, which `scripts/check-privacy.sh` enforces. It only asks whether a new version
/// exists, and it never sends anything from your recordings.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    /// Updates stay off until a build has a feed and a signing key. Those belong to the
    /// release, so a development build simply has no updater.
    init() {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool {
        controller != nil
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }
}
