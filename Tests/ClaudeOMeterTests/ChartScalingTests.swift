import XCTest
import Charts
@testable import ClaudeOMeter

final class ChartScalingTests: XCTestCase {

    // MARK: - yMax

    func testYMaxAddsHeadroomAboveData() {
        // No limit → 10% headroom above the data peak.
        XCTAssertEqual(ChartScaling.yMax(dataMax: 100, limit: nil), 110, accuracy: 1e-9)
    }

    func testYMaxUsesLimitWhenTallerThanData() {
        // Limit above the data peak drives the scale so the rule line stays on-chart.
        XCTAssertEqual(ChartScaling.yMax(dataMax: 50, limit: 200), 220, accuracy: 1e-9)
    }

    func testYMaxUsesDataWhenTallerThanLimit() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 300, limit: 100), 330, accuracy: 1e-9)
    }

    func testYMaxFloorsAllZeroChart() {
        // An all-zero day still gets a sane positive scale from the floor.
        XCTAssertEqual(ChartScaling.yMax(dataMax: 0, limit: nil, floor: 0.01), 0.011, accuracy: 1e-9)
    }

    func testYMaxRespectsCustomFloor() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 0, limit: nil, floor: 1.0), 1.1, accuracy: 1e-9)
    }

    // MARK: - alertAnnotationPosition

    func testAnnotationBelowWhenUnderBudget() {
        // Data below the limit → label sits below the high line (clear space, no top clip).
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 40, limit: 100), .bottom)
    }

    func testAnnotationAboveWhenOverBudget() {
        // Data has crossed the limit → label flips above the now-buried line.
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 150, limit: 100), .top)
    }

    func testAnnotationAboveExactlyAtLimit() {
        // At exactly the limit the data reaches the line → above.
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 100, limit: 100), .top)
    }

    func testAnnotationDefaultsBottomWhenNoLimit() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 500, limit: nil), .bottom)
    }

    func testAnnotationDefaultsBottomWhenLimitZero() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 500, limit: 0), .bottom)
    }
}
