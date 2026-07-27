@testable import ClaudeOMeter
import XCTest

final class DayBucketWeekTests: XCTestCase {

    func testWeekMondayReturnsMonday() {
        // 2025-07-16 is a Wednesday
        let wed = DayBucket.date(fromDay: "2025-07-16")!
        let monday = DayBucket.weekMonday(from: wed)
        XCTAssertEqual(monday, "2025-07-14")
    }

    func testWeekMondayForMondayReturnsItself() {
        let mon = DayBucket.date(fromDay: "2025-07-14")!
        let result = DayBucket.weekMonday(from: mon)
        XCTAssertEqual(result, "2025-07-14")
    }

    func testWeekMondayForSundayReturnsPrecedingMonday() {
        // 2025-07-20 is a Sunday
        let sun = DayBucket.date(fromDay: "2025-07-20")!
        let result = DayBucket.weekMonday(from: sun)
        XCTAssertEqual(result, "2025-07-14")
    }

    func testDaysInWeekProduces7Days() {
        let days = DayBucket.daysInWeek(startingMonday: "2025-07-14")
        XCTAssertEqual(days.count, 7)
    }

    func testDaysInWeekStartsOnMonday() {
        let days = DayBucket.daysInWeek(startingMonday: "2025-07-14")
        XCTAssertEqual(days.first, "2025-07-14")
        XCTAssertEqual(days.last, "2025-07-20")
    }

    func testWeekRangeLabelFormat() {
        let label = DayBucket.weekRangeLabel(startingMonday: "2025-07-14")
        XCTAssertEqual(label, "Jul 14 – Jul 20")
    }

    func testWeekRangeLabelSpanningMonthBoundary() {
        // 2025-06-30 is a Monday, week ends Jul 6
        let label = DayBucket.weekRangeLabel(startingMonday: "2025-06-30")
        XCTAssertEqual(label, "Jun 30 – Jul 6")
    }

    func testWeekRangeLabelSpanningYearBoundary() {
        // 2025-12-29 is a Monday, week ends 2026-01-04 — includes year for disambiguation
        let label = DayBucket.weekRangeLabel(startingMonday: "2025-12-29")
        XCTAssertEqual(label, "Dec 29 – Jan 4 '26")
    }

    func testWeekMondayWeeksAgo() {
        let wed = DayBucket.date(fromDay: "2025-07-16")!
        let oneWeekAgo = DayBucket.weekMonday(weeksAgo: 1, from: wed)
        XCTAssertEqual(oneWeekAgo, "2025-07-07")
    }

    func testWeekMondayForSaturday() {
        // 2025-07-19 is a Saturday
        let sat = DayBucket.date(fromDay: "2025-07-19")!
        let result = DayBucket.weekMonday(from: sat)
        XCTAssertEqual(result, "2025-07-14")
    }

    func testWeekMondayWeeksAgoZero() {
        let wed = DayBucket.date(fromDay: "2025-07-16")!
        let current = DayBucket.weekMonday(weeksAgo: 0, from: wed)
        XCTAssertEqual(current, "2025-07-14")
    }

    func testDaysInWeekInvalidInput() {
        let days = DayBucket.daysInWeek(startingMonday: "not-a-date")
        XCTAssertEqual(days, [])
    }
}
