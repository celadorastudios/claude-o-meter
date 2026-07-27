// NOTE: This file is excluded from `swift test` (Package.swift exclude list) because
// it imports Charts which is only linkable via Xcode. Run these tests in Xcode or CI.
import XCTest
import Charts
@testable import ClaudeOMeter

final class ChartScalingTests: XCTestCase {

    // MARK: - yMax

    func testYMaxAddsHeadroomAboveData() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 100, limit: nil), 110, accuracy: 1e-9)
    }

    func testYMaxUsesLimitWhenTallerThanData() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 50, limit: 200), 220, accuracy: 1e-9)
    }

    func testYMaxUsesDataWhenTallerThanLimit() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 300, limit: 100), 330, accuracy: 1e-9)
    }

    func testYMaxFloorsAllZeroChart() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 0, limit: nil, floor: 0.01), 0.011, accuracy: 1e-9)
    }

    func testYMaxRespectsCustomFloor() {
        XCTAssertEqual(ChartScaling.yMax(dataMax: 0, limit: nil, floor: 1.0), 1.1, accuracy: 1e-9)
    }

    // MARK: - alertAnnotationPosition

    func testAnnotationBelowWhenUnderBudget() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 40, limit: 100), .bottom)
    }

    func testAnnotationAboveWhenOverBudget() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 150, limit: 100), .top)
    }

    func testAnnotationAboveExactlyAtLimit() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 100, limit: 100), .top)
    }

    func testAnnotationDefaultsBottomWhenNoLimit() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 500, limit: nil), .bottom)
    }

    func testAnnotationDefaultsBottomWhenLimitZero() {
        XCTAssertEqual(ChartScaling.alertAnnotationPosition(dataMax: 500, limit: 0), .bottom)
    }
}
