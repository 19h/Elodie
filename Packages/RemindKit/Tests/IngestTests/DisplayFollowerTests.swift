import CoreGraphics
import Foundation
@testable import Ingest
import Testing

@Suite struct DisplayFollowing {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func staysPutWhileThePointerIsOnTheCurrentDisplay() {
        var follower = DisplayFollower()
        #expect(follower.observe(pointerOn: 1, current: 1, now: start) == nil)
        #expect(follower.observe(pointerOn: 1, current: 1, now: start.addingTimeInterval(60)) == nil)
    }

    @Test func movesOnceThePointerHasSettledOnAnotherDisplay() {
        var follower = DisplayFollower()
        #expect(follower.observe(pointerOn: 2, current: 1, now: start) == nil)
        #expect(follower.observe(pointerOn: 2, current: 1, now: start.addingTimeInterval(1)) == nil)
        #expect(follower.observe(pointerOn: 2, current: 1, now: start.addingTimeInterval(2)) == 2)
    }

    @Test func aBriefCrossingDoesntCount() {
        var follower = DisplayFollower()
        _ = follower.observe(pointerOn: 2, current: 1, now: start)
        _ = follower.observe(pointerOn: 1, current: 1, now: start.addingTimeInterval(1))
        // Coming back later starts the wait over.
        #expect(follower.observe(pointerOn: 2, current: 1, now: start.addingTimeInterval(3)) == nil)
        #expect(follower.observe(pointerOn: 2, current: 1, now: start.addingTimeInterval(5)) == 2)
    }

    @Test func movingToAThirdDisplayStartsTheWaitOver() {
        var follower = DisplayFollower()
        _ = follower.observe(pointerOn: 2, current: 1, now: start)
        #expect(follower.observe(pointerOn: 3, current: 1, now: start.addingTimeInterval(5)) == nil)
        #expect(follower.observe(pointerOn: 3, current: 1, now: start.addingTimeInterval(7)) == 3)
    }
}

@Suite struct CrashLoops {
    private func freshDefaults() -> UserDefaults {
        let name = "remind-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aNormalQuitNeverCounts() {
        let guardian = CrashGuard(defaults: freshDefaults())
        for minute in 0..<10 {
            #expect(!guardian.launchShouldStayPaused(now: start.addingTimeInterval(Double(minute) * 60)))
            guardian.markCleanExit()
        }
    }

    @Test func repeatedCrashesStopTheLoop() {
        let guardian = CrashGuard(defaults: freshDefaults())
        #expect(!guardian.launchShouldStayPaused(now: start)) // First launch.
        #expect(!guardian.launchShouldStayPaused(now: start.addingTimeInterval(30)))
        #expect(!guardian.launchShouldStayPaused(now: start.addingTimeInterval(60)))
        #expect(guardian.launchShouldStayPaused(now: start.addingTimeInterval(90)))
    }

    @Test func crashesFarApartDontAddUp() {
        let guardian = CrashGuard(defaults: freshDefaults())
        for hour in 0..<10 {
            #expect(!guardian.launchShouldStayPaused(now: start.addingTimeInterval(Double(hour) * 3600)))
        }
    }

    @Test func stayingUpClearsTheCount() {
        let guardian = CrashGuard(defaults: freshDefaults())
        _ = guardian.launchShouldStayPaused(now: start)
        _ = guardian.launchShouldStayPaused(now: start.addingTimeInterval(10))
        _ = guardian.launchShouldStayPaused(now: start.addingTimeInterval(20))
        guardian.markStable()
        #expect(!guardian.launchShouldStayPaused(now: start.addingTimeInterval(30)))
    }
}
