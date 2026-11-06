@testable import Audio
import Foundation
import Testing

@Suite struct NamingMeetingsFromTheCalendar {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String?, from: TimeInterval, to: TimeInterval) -> MeetingCalendar.CalendarEvent {
        .init(title: title, start: now.addingTimeInterval(from), end: now.addingTimeInterval(to))
    }

    @Test func anEventInProgressNamesTheMeeting() {
        #expect(MeetingCalendar.bestTitle([event("Standup", from: -600, to: 600)], now: now) == "Standup")
    }

    @Test func whenEventsOverlapTheLaterOneWins() {
        let events = [event("Overrunning", from: -3600, to: 300), event("Next", from: -60, to: 1800)]
        #expect(MeetingCalendar.bestTitle(events, now: now) == "Next")
    }

    @Test func joiningEarlyStillCounts() {
        #expect(MeetingCalendar.bestTitle([event("Review", from: 120, to: 1800)], now: now) == "Review")
    }

    @Test func eventsThatAreOverOrFarOffDoNot() {
        let events = [event("Earlier", from: -7200, to: -3600), event("Later", from: 7200, to: 9000)]
        #expect(MeetingCalendar.bestTitle(events, now: now) == nil)
    }

    @Test func untitledEventsAreIgnored() {
        #expect(MeetingCalendar.bestTitle([event(nil, from: -60, to: 60), event("", from: -60, to: 60)], now: now) == nil)
    }
}
