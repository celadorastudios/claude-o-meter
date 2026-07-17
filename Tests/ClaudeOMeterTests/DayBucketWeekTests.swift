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
        XCTAssertTrue(label.contains("–"))
        XCTAssertTrue(label.contains("Jul 14"))
        XCTAssertTrue(label.contains("Jul 20"))
    }

    func testWeekMondayWeeksAgo() {
        let wed = DayBucket.date(fromDay: "2025-07-16")!
        let oneWeekAgo = DayBucket.weekMonday(weeksAgo: 1, from: wed)
        XCTAssertEqual(oneWeekAgo, "2025-07-07")
    }
}
