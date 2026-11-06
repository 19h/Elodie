@testable import Capture
import Testing

@Suite struct PrivateWindowIdentifiers {
    @Test func arcsIncognitoIdentifierCounts() {
        #expect(PrivateWindowRules.isPrivate(identifier: "bigIncognitoBrowserWindow-1234", family: .arc))
    }

    @Test func ordinaryArcWindowsDoNot() {
        #expect(!PrivateWindowRules.isPrivate(identifier: "bigBrowserWindow-1234", family: .arc))
        #expect(!PrivateWindowRules.isPrivate(identifier: nil, family: .arc))
    }

    @Test func otherBrowsersDontUseThisSignal() {
        #expect(!PrivateWindowRules.isPrivate(identifier: "incognito", family: .chromium))
    }
}
