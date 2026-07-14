import XCTest
@testable import ClaudeOMeter

final class HourlyProjectorTests: XCTestCase {

    // MARK: - Helpers

    /// Reference time: Oct 15 2025 (a Wednesday) at 10:00 local — mid-morning so there are
    /// both elapsed and remaining hours to project.
    private func fixedMorning() -> Date {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 10; comps.day = 15
        comps.hour = 10; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    private func agg(day: String, cost: Double) -> DailyAggregate {
        var a = DailyAggregate(day: day)
        a.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "sonnet", usage: TokenUsage(), cost: cost)
        return a
    }

    /// Steady $100/day history for the last 30 days.
    private func steadyHistory(now: Date, perDay: Double = 100) -> [String: DailyAggregate] {
        Dictionary((1...30).map { d -> (String, DailyAggregate) in
            let day = DayBucket.day(daysAgo: d, from: now)
            return (day, agg(day: day, cost: perDay))
        }, uniquingKeysWith: { a, _ in a })
    }

    private func slice(_ hour: Int, _ cost: Double) -> HourlySlice {
        HourlySlice(hour: hour, cost: cost, perModel: ["sonnet": cost])
    }

    // MARK: - Suppression

    func testSuppressedForPastDay() {
        let now = fixedMorning()
        let forecasts = HourlyProjector.forecast(
            slices: (0...23).map { slice($0, 2.0) },
            aggregates: steadyHistory(now: now),
            todayKey: DayBucket.localDay(from: now),
            isToday: false,
            now: now
        )
        XCTAssertTrue(forecasts.isEmpty, "A completed past day has nothing to project")
    }

    func testSuppressedAtLastHour() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 10; comps.day = 15; comps.hour = 23
        let lateNight = Calendar.current.date(from: comps)!
        let forecasts = HourlyProjector.forecast(
            slices: (0...23).map { slice($0, 1.0) },
            aggregates: steadyHistory(now: lateNight),
            todayKey: DayBucket.localDay(from: lateNight),
            isToday: true,
            now: lateNight
        )
        XCTAssertTrue(forecasts.isEmpty, "Nothing left to project at hour 23")
    }

    func testSuppressedWhenNoSpendAndNoHistory() {
        let now = fixedMorning()
        let forecasts = HourlyProjector.forecast(
            slices: [],
            aggregates: [:],
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        XCTAssertTrue(forecasts.isEmpty, "No pace and no history ⇒ nothing to project")
    }

    /// The tightest valid range: at 22:00 exactly one hour (23) remains. Complements the
    /// midnight case at the other extreme and guards the `(currentHour + 1)...23` range from
    /// an off-by-one that would make it empty or crash.
    func testLastProjectableHourYieldsSingleForecast() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 10; comps.day = 15; comps.hour = 22; comps.minute = 0
        let lateEvening = Calendar.current.date(from: comps)!

        let forecasts = HourlyProjector.forecast(
            slices: [slice(21, 10.0)],
            aggregates: steadyHistory(now: lateEvening),
            todayKey: DayBucket.localDay(from: lateEvening),
            isToday: true,
            now: lateEvening
        )
        XCTAssertEqual(forecasts.map { $0.hour }, [23], "Only hour 23 remains at 22:00")
        XCTAssertGreaterThanOrEqual(forecasts.first?.cost ?? -1, 0)
    }

    // MARK: - Coverage of remaining hours

    func testForecastsCoverRemainingHours() {
        let now = fixedMorning()   // hour 10
        let forecasts = HourlyProjector.forecast(
            slices: [slice(8, 10), slice(9, 10)],
            aggregates: steadyHistory(now: now),
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        XCTAssertEqual(forecasts.map { $0.hour }, Array(11...23), "One forecast per remaining hour")
        for f in forecasts { XCTAssertGreaterThanOrEqual(f.cost, 0) }
    }

    // MARK: - History dominates early in the day

    func testHistoryDominatesEarlyInDay() {
        let now = fixedMorning()   // hour 10, ~42% elapsed
        // Only a tiny amount spent so far, but history says ~$100/day.
        let withHistory = HourlyProjector.forecast(
            slices: [slice(9, 2.0)],
            aggregates: steadyHistory(now: now, perDay: 100),
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        let projectedRemainder = withHistory.reduce(0) { $0 + $1.cost }
        // With history the remaining budget should be substantial (pulled toward ~$100/day),
        // far above the ~$2.8 a pure pace extrapolation of $2 over 10h would give.
        XCTAssertGreaterThan(projectedRemainder, 20.0,
                             "History expectation should lift an early-day, low-spend projection")
    }

    func testTodayPaceMattersWithoutHistory() {
        let now = fixedMorning()   // hour 10
        // No history, but a strong pace today → projection driven purely by today.
        let forecasts = HourlyProjector.forecast(
            slices: [slice(8, 30), slice(9, 30)],
            aggregates: [:],
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        let remainder = forecasts.reduce(0) { $0 + $1.cost }
        XCTAssertGreaterThan(remainder, 0, "Today's pace alone should still yield a projection")
    }

    // MARK: - Intra-day shape (taper)

    func testProjectionTapersIntoEvening() {
        let now = fixedMorning()   // hour 10
        let forecasts = HourlyProjector.forecast(
            slices: [slice(8, 20), slice(9, 20)],
            aggregates: steadyHistory(now: now),
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        let byHour = Dictionary(uniqueKeysWithValues: forecasts.map { ($0.hour, $0.cost) })
        // Late-evening hours should be projected lower than afternoon-peak hours.
        let afternoon = byHour[14] ?? 0   // afternoon peak
        let lateEvening = byHour[23] ?? 0 // taper
        XCTAssertGreaterThan(afternoon, lateEvening,
                             "Afternoon peak hour should carry more projected spend than the 11pm taper")
    }

    // MARK: - Remaining budget is history-driven, not double-counted (C1)

    /// The documented core: with usable history H, the total projected remainder equals the
    /// still-unelapsed slice of H, `(1 − elapsedFraction) · H`, and is INDEPENDENT of how much
    /// was spent today (today enters once, through H, not a second time via a pace term). Two
    /// runs at the same hour with very different today-spend must yield the same remainder.
    func testRemainingBudgetEqualsUnelapsedHistoryFraction() {
        let now = fixedMorning()   // hour 10:00 → elapsed 10.0, ef = 10/24
        let ef = 10.0 / 24.0

        // Resolve H directly from SpendProjector for the same inputs so the assertion pins the
        // actual value, not an approximation.
        let history = steadyHistory(now: now, perDay: 100)
        let todayKey = DayBucket.localDay(from: now)
        let H = SpendProjector.forecast(aggregates: history, futureDays: [todayKey],
                                        todayKey: todayKey, now: now).first?.cost ?? 0
        XCTAssertGreaterThan(H, 0, "Precondition: history expectation is usable")
        let expectedRemainder = (1 - ef) * H

        func remainder(todaySpend: Double) -> Double {
            HourlyProjector.forecast(
                slices: [slice(9, todaySpend)],
                aggregates: history,
                todayKey: todayKey,
                isToday: true,
                now: now
            ).reduce(0) { $0 + $1.cost }
        }

        // Light day and heavy day → identical remainder (pace term cancels; no double-count).
        XCTAssertEqual(remainder(todaySpend: 1.0), expectedRemainder, accuracy: 1e-6)
        XCTAssertEqual(remainder(todaySpend: 90.0), expectedRemainder, accuracy: 1e-6)
    }

    // MARK: - Non-negative

    func testAllForecastsNonNegative() {
        let now = fixedMorning()
        let forecasts = HourlyProjector.forecast(
            slices: [slice(9, 5)],
            aggregates: steadyHistory(now: now),
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        for f in forecasts { XCTAssertGreaterThanOrEqual(f.cost, 0) }
    }

    // MARK: - Midnight boundary (T2)

    /// At 00:00 the elapsed clamp (safeElapsed = 0.5) engages the ×48 extrapolation regime.
    /// With no history, target = spentSoFar × 48; forecasts cover hours 1…23 and total to
    /// (target − spentSoFar).
    func testMidnightBoundaryUsesElapsedClampWithoutHistory() {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 10; comps.day = 15; comps.hour = 0; comps.minute = 0
        let midnight = Calendar.current.date(from: comps)!

        let forecasts = HourlyProjector.forecast(
            slices: [slice(0, 1.0)],           // $1 spent in the first hour
            aggregates: [:],                    // no history → pure pace path
            todayKey: DayBucket.localDay(from: midnight),
            isToday: true,
            now: midnight
        )
        XCTAssertEqual(forecasts.map { $0.hour }, Array(1...23), "Covers every remaining hour")
        // target = 1.0 × (24 / 0.5) = 48; remaining = 48 − 1 = 47.
        let remainder = forecasts.reduce(0) { $0 + $1.cost }
        XCTAssertEqual(remainder, 47.0, accuracy: 1e-6, "×48 clamp regime at midnight")
    }

    // MARK: - Projection never regresses below spend-so-far (T3)

    /// By construction the blended target is `(1 - ef)·history + ef·todayExtrapolation`, and
    /// `ef·todayExtrapolation == spentSoFar` exactly (todayExtrapolation = spentSoFar·24/elapsed,
    /// ef = elapsed/24). So the projected end-of-day total is always ≥ spend-so-far — the dashed
    /// continuation never bends backward, even on a heavy over-spend day. The only reachable
    /// suppression is the no-data case (covered by testSuppressedWhenNoSpendAndNoHistory).
    func testOverSpendDoesNotSuppressAndTotalDoesNotRegress() {
        let now = fixedMorning()   // hour 10
        let spent = 500.0
        let forecasts = HourlyProjector.forecast(
            slices: [slice(9, spent)],                      // far above the $80/day history
            aggregates: steadyHistory(now: now, perDay: 80),
            todayKey: DayBucket.localDay(from: now),
            isToday: true,
            now: now
        )
        XCTAssertFalse(forecasts.isEmpty, "Over-spending must not blank the projection")
        let projectedTotal = spent + forecasts.reduce(0) { $0 + $1.cost }
        XCTAssertGreaterThanOrEqual(projectedTotal, spent, "Projected end-of-day total never regresses below spend so far")
    }

    // MARK: - Blend weighting is directional (T1)

    /// The blend must weight history more heavily early in the day and today's pace more
    /// heavily late in the day. A test at two different hours pins the direction so a swap of
    /// the interpolation coefficients would fail.
    func testBlendShiftsFromHistoryTowardTodayAsDayProgresses() {
        func projectedTotal(atHour hour: Int) -> Double {
            var comps = DateComponents()
            comps.year = 2025; comps.month = 10; comps.day = 15; comps.hour = hour; comps.minute = 0
            let when = Calendar.current.date(from: comps)!
            // Today running LIGHT relative to a rich $150/day history: $1/elapsed-hour.
            let slices = (0...hour).map { slice($0, 1.0) }
            let spent = Double(hour + 1) * 1.0
            let forecasts = HourlyProjector.forecast(
                slices: slices,
                aggregates: steadyHistory(now: when, perDay: 150),
                todayKey: DayBucket.localDay(from: when),
                isToday: true,
                now: when
            )
            return spent + forecasts.reduce(0) { $0 + $1.cost }   // projected end-of-day total
        }

        let earlyTotal = projectedTotal(atHour: 2)    // ~12.5% elapsed → history dominates
        let lateTotal  = projectedTotal(atHour: 20)   // ~87.5% elapsed → today dominates

        // History ($150/day) >> today's pace ($24/day). Early, the blend leans on history so
        // the projected total is high; late, it leans on today's light pace so it's lower.
        // If the weights were swapped, this ordering would invert.
        XCTAssertGreaterThan(earlyTotal, lateTotal,
                             "Early-day projection should lean on (rich) history; late-day on (light) today")
        XCTAssertGreaterThan(earlyTotal, 80.0, "Early projection pulled toward $150/day history")
        XCTAssertLessThan(lateTotal, 60.0, "Late projection pulled toward today's light pace")
    }
}
