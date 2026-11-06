import Capture
import FeatureOnboarding
import ServiceManagement

/// What differs between the direct download and the App Store build.
///
/// The App Store requires the App Sandbox, where macOS refuses to let one app read another
/// through Accessibility, even with permission. A sandboxed build with a grant left over from
/// a direct download would be told it's trusted and then get errors, and an error from a
/// browser means its frames get dropped. So the App Store build has none of that code at all.
enum Edition {
    #if ELODIE_APP_STORE
    static let readFrontWindow: FrontWindowReader = { _, _ in .failure(.notTrusted) }
    static let accessibility: AccessibilityAccess? = nil
    /// Starting with the Mac is all this does. Coming back after a crash, or after a force
    /// quit, could count as running after being quit, which App Review doesn't allow.
    static var loginItem: SMAppService { .mainApp }
    static let privateWindowNote = String(
        localized: "Elodie spots private windows by their titles. Arc can't be recorded, because its titles don't say."
    )
    #else
    static let readFrontWindow: FrontWindowReader = { pid, family in
        AccessibilityProbe.frontWindow(pid: pid, family: family)
    }
    static let accessibility: AccessibilityAccess? = AccessibilityProbe.access
    /// Starts with the Mac, and launchd brings it back after a crash.
    static var loginItem: SMAppService { .agent(plistName: "com.kenansulayman.Elodie.agent.plist") }
    static let privateWindowNote = String(
        localized: "Accessibility is off for Elodie, so it can only spot private windows by their titles, and Arc can't be recorded."
    )
    #endif
}
