import EventKit
import Foundation

/// Names meetings from the calendar. It only ever reads events, only after being turned on
/// in Settings, and titles stay on this Mac with the transcript they name.
public final class MeetingCalendar: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for access, and returns whether it's available.
    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The title of the event most likely to be this meeting.
    public func currentEventTitle(now: Date = Date()) -> String? {
        guard Self.hasAccess else { return nil }
        let window = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.earlyStart),
            end: now.addingTimeInterval(Self.earlyStart),
            calendars: nil
        )
        let events = store.events(matching: window).filter { !$0.isAllDay }.map {
            CalendarEvent(title: $0.title, start: $0.startDate, end: $0.endDate)
        }
        return Self.bestTitle(events, now: now)
    }

    /// People join a little early, so an event about to start counts.
    private static let earlyStart: TimeInterval = 5 * 60

    public struct CalendarEvent: Sendable {
        public var title: String?
        public var start: Date
        public var end: Date

        public init(title: String?, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Prefers an event in progress, the one that started most recently, since a meeting
    /// that overruns can overlap the next. Otherwise, the next one about to start.
    public static func bestTitle(_ events: [CalendarEvent], now: Date) -> String? {
        let titled = events.filter { !($0.title ?? "").isEmpty }
        let current = titled.filter { $0.start <= now && now < $0.end }
        if let latest = current.max(by: { $0.start < $1.start }) {
            return latest.title
        }
        return titled
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= earlyStart }
            .min(by: { $0.start < $1.start })?
            .title
    }
}
