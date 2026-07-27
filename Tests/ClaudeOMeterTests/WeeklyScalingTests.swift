@testable import ClaudeOMeter
import XCTest

final class WeeklyScalingTests: XCTestCase {

    func testWeeklyDataMaxIncludesProjection() {
        let actuals = [5.0, 8.0, 3.0, 2.0]
        let projections = [0.0, 0.0, 0.0, 12.0]
        let result = ChartScaling.weeklyDataMax(bucketActuals: actuals, bucketProjections: projections)
        XCTAssertEqual(result, 14.0, accuracy: 1e-9)
    }

    func testWeeklyDataMaxNoProjectionUsesActual() {
        let actuals = [5.0, 8.0, 3.0, 10.0]
        let projections = [0.0, 0.0, 0.0, 0.0]
        let result = ChartScaling.weeklyDataMax(bucketActuals: actuals, bucketProjections: projections)
        XCTAssertEqual(result, 10.0, accuracy: 1e-9)
    }

    func testWeeklyDataMaxFloorsAtOne() {
        let actuals = [0.0, 0.0, 0.0, 0.0]
        let projections = [0.0, 0.0, 0.0, 0.0]
        let result = ChartScaling.weeklyDataMax(bucketActuals: actuals, bucketProjections: projections)
        XCTAssertEqual(result, 1.0, accuracy: 1e-9)
    }

    func testWeeklyDataMaxProjectionDominatesEarlyWeek() {
        let actuals = [20.0, 15.0, 18.0, 3.0]
        let projections = [0.0, 0.0, 0.0, 25.0]
        let result = ChartScaling.weeklyDataMax(bucketActuals: actuals, bucketProjections: projections)
        XCTAssertEqual(result, 28.0, accuracy: 1e-9)
    }
}
