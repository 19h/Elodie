import Foundation

/// Understands dates as people type them, such as "yesterday 3pm" or "March 4".
public enum NaturalDate {
    /// The moment a phrase means, always in the past, because that's all there is to see.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              var date = detector.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              )?.date
        else { return nil }
        // A phrase with no year or day usually means the most recent time it happened:
        // "3pm" at 10am was yesterday, and "March 4" in November was this year's.
        if date > now, date.timeIntervalSince(now) <= 86_400 {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        while date > now, let earlier = calendar.date(byAdding: .year, value: -1, to: date) {
            date = earlier
        }
        return date
    }
}
