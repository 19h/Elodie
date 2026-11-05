import Foundation

/// Recognises private browser windows from their titles.
///
/// Browsers offer no API for this, and they translate these words. So this table
/// has to cover the languages people use, which the reference app didn't: it only
/// checked English. A language missing here means private windows aren't detected
/// in it, so the Screen settings tab warns about languages it can't confirm.
public enum PrivateWindowRules {
    /// Words browsers put in a private window's title, in lowercase.
    private static let markers: [String] = [
        // English
        "incognito", "private browsing", "(private)", "inprivate", "- private",
        // German
        "inkognito", "privates surfen", "privater modus", "(privat)", "- privat",
        // French
        "navigation privée", "(privé)", "- privé",
        // Spanish, Italian, Portuguese
        "incógnito", "navegación privada", "(privada)", "navigazione privata", "(privata)",
        "navegação privada", "anônimo", "anónimo",
        // Dutch, Swedish, Danish, Norwegian, Polish
        "privénavigatie", "privat surfning", "privat browsing", "prywatne",
        // Russian, Ukrainian
        "инкогнито", "приватный", "приватне", "інкогніто",
        // Chinese, Japanese, Korean
        "无痕", "無痕", "隐私", "隱私", "シークレット", "プライベート", "시크릿", "개인 정보 보호",
    ]

    /// Whether a window title marks a private window.
    ///
    /// Only the end of the title is checked for Chromium browsers, where the
    /// browser adds its marker after the page title. Otherwise a page *about*
    /// incognito mode would hide a normal window from recording.
    public static func isPrivate(title: String?, family: BrowserFamily) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        switch family {
        case .chromium, .arc:
            let tail = chromiumTail(of: lowered)
            return markers.contains { tail.contains($0) }
        case .webkit, .gecko:
            return markers.contains { lowered.hasSuffix($0) || endsWithMarkerSegment(lowered, $0) }
        }
    }

    /// Whether a window's Accessibility identifier marks it as private. Arc names its
    /// incognito windows this way, in every language.
    public static func isPrivate(identifier: String?, family: BrowserFamily) -> Bool {
        guard family == .arc, let identifier else { return false }
        return identifier.lowercased().contains("incognito")
    }

    /// The last ` - ` part of a Chromium title, or the whole title with no separator.
    private static func chromiumTail(of title: String) -> String {
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator, options: .backwards) {
                return "- " + title[range.upperBound...]
            }
        }
        return title
    }

    /// Safari ends titles with `, Private Browsing`, and Firefox with
    /// `— Mozilla Firefox Private Browsing`.
    private static func endsWithMarkerSegment(_ title: String, _ marker: String) -> Bool {
        guard let range = title.range(of: marker, options: .backwards) else { return false }
        let after = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return after.isEmpty || after == ")"
    }
}
