import Foundation

/// Parses ISO-8601 timestamps and keeps local display days separate from UTC pricing days.
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

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func utcDay(from date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

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
}
