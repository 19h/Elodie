import Foundation

/// How to look for the answer to a question.
public struct SearchPlan: Equatable, Sendable {
    public var keywords: [String]
    public var from: Date?
    public var to: Date?

    public init(keywords: [String], from: Date? = nil, to: Date? = nil) {
        self.keywords = keywords
        self.from = from
        self.to = to
    }
}

/// Turns a question into words to search for and a time to look in. This runs on the
/// device with no model involved, so it's instant and always available.
public enum QuestionPlanner {
    /// Words that say nothing about what to look for. Screen text is often German or
    /// English, so both are covered.
    private static let stopWords: Set<String> = [
        // English
        "a", "about", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at", "be",
        "been", "before", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "for",
        "from", "get", "got", "had", "has", "have", "how", "i", "if", "in", "into", "is", "it",
        "its", "just", "last", "look", "looked", "looking", "me", "my", "of", "on", "or", "our",
        "saw", "see", "seen", "she", "he", "should", "show", "so", "some", "tell", "that", "the",
        "their", "them", "then", "there", "they", "this", "to", "today", "tomorrow", "us", "was",
        "we", "were", "what", "when", "where", "which", "who", "whom", "why", "will", "with",
        "would", "yesterday", "you", "your", "week", "month", "morning", "afternoon", "evening",
        "ago", "remember", "find", "said", "say", "says", "talk", "talked", "talking",
        // German
        "aber", "alle", "als", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "das", "dass",
        "dem", "den", "der", "des", "die", "dir", "du", "ein", "eine", "einem", "einen", "einer",
        "er", "es", "für", "gestern", "habe", "haben", "hat", "heute", "ich", "ihr", "im", "in",
        "ist", "ja", "kann", "mein", "meine", "mich", "mir", "mit", "nach", "nicht", "noch", "oder",
        "sie", "sind", "um", "und", "uns", "von", "vor", "war", "was", "welche", "wer", "wie", "wir",
        "wo", "zu", "zum", "zur",
    ]

    public static func plan(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> SearchPlan {
        var keywords: [String] = []
        // A quoted phrase means exactly that phrase, so it's kept whole.
        var rest = question
        while let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") {
            let phrase = rest[rest.index(after: open)..<close]
            if !phrase.isEmpty { keywords.append("\"\(phrase)\"") }
            rest.removeSubrange(open...close)
        }

        var seen = Set<String>()
        for word in rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let lowered = word.lowercased()
            if word.count < 2 && !word.allSatisfy(\.isNumber) { continue }
            if stopWords.contains(lowered) { continue }
            if seen.insert(lowered).inserted { keywords.append(String(word)) }
        }

        let (from, to) = timeRange(in: question, now: now, calendar: calendar)
        return SearchPlan(keywords: keywords, from: from, to: to)
    }

    /// Finds when a question is asking about, if it says.
    private static func timeRange(in question: String, now: Date, calendar: Calendar) -> (Date?, Date?) {
        let lowered = question.lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> (Date?, Date?) {
            let start = calendar.date(byAdding: .day, value: offset, to: today)
            let end = start.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            return (start, end)
        }
        if lowered.contains("yesterday") || lowered.contains("gestern") { return day(-1) }
        if lowered.contains("today") || lowered.contains("heute") { return (today, now) }
        if lowered.contains("last week") || lowered.contains("letzte woche") {
            return (calendar.date(byAdding: .day, value: -7, to: today), now)
        }
        if lowered.contains("last month") || lowered.contains("letzten monat") {
            return (calendar.date(byAdding: .month, value: -1, to: today), now)
        }
        // A specific date, such as "on March 3".
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
           let date = match.date {
            let start = calendar.startOfDay(for: date)
            return (start, calendar.date(byAdding: .day, value: 1, to: start))
        }
        return (nil, nil)
    }
}
