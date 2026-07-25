import XCTest
@testable import ClaudeOMeter

final class SessionNudgeTests: XCTestCase {

    private func midday() -> Date {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 7; comps.day = 22
        comps.hour = 14; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    private func aggWithOpus(cost: Double, totalCost: Double? = nil) -> DailyAggregate {
        var agg = DailyAggregate(day: "2025-07-22")
        agg.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8", cost: cost)
        if let extra = totalCost, extra > cost {
            agg.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-5", cost: extra - cost)
        }
        return agg
    }

    func testNudgeFiresWhenOpusHeavyAndExpensive() {
        let agg = aggWithOpus(cost: 80.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil, now: midday())
        XCTAssertTrue(decision.shouldNudge)
        XCTAssertTrue(decision.suggestion.contains("Sonnet"))
    }

    func testNudgeDoesNotFireWhenCostIsLow() {
        let agg = aggWithOpus(cost: 2.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil, now: midday())
        XCTAssertFalse(decision.shouldNudge)
    }

    func testNudgeDoesNotFireWhenOpusFractionIsLow() {
        let agg = aggWithOpus(cost: 5.0, totalCost: 80.0)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: nil, now: midday())
        XCTAssertFalse(decision.shouldNudge)
    }

    func testNudgeRespectsCoolddown() {
        let agg = aggWithOpus(cost: 80.0)
        let recentNudge = midday().addingTimeInterval(-30 * 60)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: recentNudge, now: midday())
        XCTAssertFalse(decision.shouldNudge, "Should not nudge within cooldown period")
    }

    func testNudgeFiresAfterCooldown() {
        let agg = aggWithOpus(cost: 80.0)
        let oldNudge = midday().addingTimeInterval(-90 * 60)
        let decision = SessionNudge.evaluate(todayAggregate: agg, lastNudgeTime: oldNudge, now: midday())
        XCTAssertTrue(decision.shouldNudge)
    }

    func testNudgeDoesNotFireWithNoAggregate() {
        let decision = SessionNudge.evaluate(todayAggregate: nil, lastNudgeTime: nil, now: midday())
        XCTAssertFalse(decision.shouldNudge)
    }
}
