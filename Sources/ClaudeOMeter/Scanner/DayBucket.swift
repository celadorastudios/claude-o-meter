import Foundation

/// Converts ISO-8601 timestamps to local calendar-day strings ("yyyy-MM-dd").
enum DayBucket {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(fromDay day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    static func date(fromISO ts: String) -> Date? {
        iso.date(from: ts) ?? isoNoFrac.date(from: ts)
    }

    static func localDay(fromISO ts: String) -> String? {
        guard let d = date(fromISO: ts) else { return nil }
        return dayFormatter.string(from: d)
    }

    static func localDay(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// "yyyy-MM-dd" for the day that is `daysAgo` before `from` (local time).
    static func day(daysAgo: Int, from: Date = Date()) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: from) ?? from
        return localDay(from: d)
    }

    // MARK: - Week helpers

    private static let gregorian = Calendar(identifier: .gregorian)

    /// The Monday of the ISO week containing `date`, as "yyyy-MM-dd".
    static func weekMonday(from date: Date = Date()) -> String {
        let weekday = gregorian.component(.weekday, from: date)
        // .weekday: 1=Sun, 2=Mon, ... 7=Sat. Offset to Monday-based.
        let daysFromMonday = (weekday + 5) % 7
        let monday = gregorian.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date
        return localDay(from: monday)
    }

    /// The Monday of the week `weeksAgo` weeks before the week containing `date`.
    static func weekMonday(weeksAgo: Int, from date: Date = Date()) -> String {
        let shifted = gregorian.date(byAdding: .weekOfYear, value: -weeksAgo, to: date) ?? date
        return weekMonday(from: shifted)
    }

    /// All 7 days (Mon–Sun) for the week whose Monday is `monday`.
    static func daysInWeek(startingMonday monday: String) -> [String] {
        guard let start = date(fromDay: monday) else { return [] }
        return (0..<7).map { offset in
            let d = gregorian.date(byAdding: .day, value: offset, to: start) ?? start
            return localDay(from: d)
        }
    }

    /// Human-readable range label: "Jun 30 – Jul 6" or "Dec 29 – Jan 4 '26" when spanning years.
    static func weekRangeLabel(startingMonday monday: String) -> String {
        let days = daysInWeek(startingMonday: monday)
        guard let first = days.first, let last = days.last else { return monday }
        let firstYear = first.prefix(4)
        let lastYear = last.prefix(4)
        if firstYear != lastYear {
            return "\(shortDate(first)) – \(shortDateWithYear(last))"
        }
        return "\(shortDate(first)) – \(shortDate(last))"
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    private static let shortDateYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d ''yy"
        return f
    }()

    private static func shortDate(_ day: String) -> String {
        guard let d = date(fromDay: day) else { return day }
        return shortDateFormatter.string(from: d)
    }

    private static func shortDateWithYear(_ day: String) -> String {
        guard let d = date(fromDay: day) else { return day }
        return shortDateYearFormatter.string(from: d)
    }
}
