import XCTest
@testable import ClaudeOMeter

final class SessionNudgeTests: XCTestCase {

    private func aggWithOpus(cost: Double, totalCost: Double? = nil) -> DailyAggregate {
        var agg = DailyAggregate(day: "2025-07-22")
        agg.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8", cost: cost)
        if let extra = totalCost, extra > cost {
            agg.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-5", cost: extra - cost)
        }
        return agg
    }

    func testNudgeFiresWhenOpusHeavyAndExpensive() {
        let agg = aggWithOpus(cost: 50.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil)
        XCTAssertTrue(decision.shouldNudge)
        XCTAssertTrue(decision.suggestion.contains("Sonnet"))
    }

    func testNudgeDoesNotFireWhenCostBelowThreshold() {
        let agg = aggWithOpus(cost: 20.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil)
        XCTAssertFalse(decision.shouldNudge)
    }

    func testNudgeDoesNotFireWhenOpusFractionIsLow() {
        let agg = aggWithOpus(cost: 35.0, totalCost: 200.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil)
        XCTAssertFalse(decision.shouldNudge, "Opus is only 17.5% — should not nudge")
    }

    func testNudgeRespectsCooldown() {
        let agg = aggWithOpus(cost: 50.0)
        let recentNudge = Date().addingTimeInterval(-30 * 60)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: recentNudge)
        XCTAssertFalse(decision.shouldNudge, "Should not nudge within cooldown period")
    }

    func testNudgeFiresAfterCooldown() {
        let agg = aggWithOpus(cost: 50.0)
        let oldNudge = Date().addingTimeInterval(-90 * 60)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: oldNudge)
        XCTAssertTrue(decision.shouldNudge)
    }

    func testNudgeDoesNotFireWithNoAggregate() {
        let decision = SessionNudge.evaluate(todayAggregate: nil, lastNudgeTime: nil)
        XCTAssertFalse(decision.shouldNudge)
    }

    func testNudgeDoesNotFireJustBelowThreshold() {
        let agg = aggWithOpus(cost: 29.99)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil)
        XCTAssertFalse(decision.shouldNudge)
    }

    func testNudgeFiresAtExactThreshold() {
        let agg = aggWithOpus(cost: 30.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil)
        XCTAssertTrue(decision.shouldNudge)
    }
}
