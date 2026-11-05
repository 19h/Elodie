import Foundation

/// How the playhead describes when a moment was.
public enum TimeLabel {
    /// Recent moments read as "23 seconds ago", and older ones as a time and date.
    public static func text(
        for moment: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let seconds = now.timeIntervalSince(moment)
        if seconds < 5 {
            return String(localized: "Just now")
        }
        if seconds < 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .numeric
            return formatter.localizedString(fromTimeInterval: -seconds.rounded())
        }

        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        if calendar.isDate(moment, inSameDayAs: now) {
            return moment.formatted(style)
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: moment),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 {
            return moment.formatted(style.weekday(.abbreviated))
        }
        let sameYear = calendar.component(.year, from: moment) == calendar.component(.year, from: now)
        var dated = style.month(.abbreviated).day()
        if !sameYear {
            dated = dated.year()
        }
        return moment.formatted(dated)
    }
}
