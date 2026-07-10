import XCTest
@testable import ClaudeOMeter

final class PatternDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Build an aggregate for the given day with specified per-model costs and usage.
    private func agg(day: String, model: String = "sonnet", rawModel: String = "claude-sonnet-4-6",
                     input: Int = 0, output: Int = 0,
                     cacheRead: Int = 0, cacheWrite5m: Int = 0) -> (String, DailyAggregate) {
        let usage = TokenUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite5m)
        let pricing = PricingTable.default
        let cost = pricing.cost(of: usage, family: model, rawModel: rawModel)
        var agg = DailyAggregate(day: day)
        agg.perModel[model] = ModelUsage(model: model, rawModel: rawModel, usage: usage, cost: cost)
        return (day, agg)
    }

    /// Fake aggregates with uniform $1/day spend across `n` days ending `endDaysAgo` (exclusive today = 0).
    private func uniformAggs(perDay: Double = 1.0, from startDaysAgo: Int = 1, count: Int = 14, now: Date = Date()) -> [String: DailyAggregate] {
        var result: [String: DailyAggregate] = [:]
        for offset in startDaysAgo..<(startDaysAgo + count) {
            let day = DayBucket.day(daysAgo: offset, from: now)
            var dailyAgg = DailyAggregate(day: day)
            dailyAgg.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                                      usage: TokenUsage(), cost: perDay)
            result[day] = dailyAgg
        }
        return result
    }

    // MARK: - Guard: returns empty when total < $0.50

    func testDetectReturnsEmptyWhenSpendTooLow() {
        var aggs: [String: DailyAggregate] = [:]
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                              usage: TokenUsage(), cost: 0.02)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs)
        XCTAssertTrue(insights.isEmpty, "Expected empty insights when 7-day spend < $0.50")
    }

    // MARK: - Cache efficiency

    func testCacheMissDetected() {
        // 100K input, zero cache read → hitRate = 0% < 15%
        var aggs = uniformAggs(perDay: 1.0)
        let day = DayBucket.day(daysAgo: 1)
        var d = DailyAggregate(day: day)
        d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                           usage: TokenUsage(input: 100_000), cost: 1.0)
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs)
        XCTAssertTrue(insights.contains { $0.id == "cache_miss" })
    }

    func testHighCacheHitRateDetected() {
        // 10K input + 90K cacheRead → hitRate = 90% ≥ 50%
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                           usage: TokenUsage(input: 10_000, cacheRead: 90_000), cost: 1.0)
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "cache_high" })
    }

    func testCacheEfficiencyNotFiredWhenCacheableBelowThreshold() {
        // cacheable = 30K < 50K threshold → neither cache insight fires
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                           usage: TokenUsage(input: 30_000), cost: 1.0)
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertFalse(insights.contains { $0.id == "cache_miss" })
        XCTAssertFalse(insights.contains { $0.id == "cache_high" })
    }

    // MARK: - Model selection

    func testOpusHeavyDetected() {
        // 7-day spend ≥ $1 and opus > 60% of it
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                             usage: TokenUsage(), cost: 0.80)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 0.20)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "opus_heavy" })
    }

    func testModelEfficientDetected() {
        // 7-day spend ≥ $2 and opus < 40% of it
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                             usage: TokenUsage(), cost: 0.20)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 0.80)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "model_efficient" })
    }

    // MARK: - Spend trend

    func testSpendSpikeDetected() {
        // last7 avg = $2/day, prior7 avg = $1/day → 100% increase ≥ 60% threshold
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 2.0)
            aggs[day] = d
        }
        for i in 8...14 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 1.0)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "spend_spike" })
    }

    func testSpendDownDetected() {
        // last7 avg = $0.50/day, prior7 avg = $2/day → 75% decrease ≥ 30% threshold
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 0.50)
            aggs[day] = d
        }
        for i in 8...14 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 2.0)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "spend_down" })
    }

    // MARK: - Context bloat

    func testContextBloatDetected() {
        // 12M opus taxable cache-read → $6.00 recoverable: clears the $5 floor and is
        // well above 5% of the ~$7 seven-day spend.
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                        usage: TokenUsage(cacheRead: 12_000_000), cost: 1.0)
        d.taxableCacheRead["opus"] = 12_000_000
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, pricing: .default, now: now)
        let bloat = insights.first { $0.id == "context_bloat" }
        XCTAssertNotNil(bloat)
        // 12M cache-read × $0.50/1M (opus family fallback) = $6.00.
        XCTAssertTrue(bloat?.title.contains("$6.00") ?? false, "title was: \(bloat?.title ?? "nil")")
    }

    func testContextBloatUsesExactPerVersionRate() {
        // claude-opus-4-1 cache-read is $1.50/1M exact (3× the family fallback). The insight
        // must price with the day's rawModel, so 4M tokens → $6.00, not $2.00.
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-1",
                                        usage: TokenUsage(cacheRead: 4_000_000), cost: 1.0)
        d.taxableCacheRead["opus"] = 4_000_000
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, pricing: .default, now: now)
        let bloat = insights.first { $0.id == "context_bloat" }
        XCTAssertNotNil(bloat, "4M × $1.50/1M = $6.00 should clear the $5 floor")
        XCTAssertTrue(bloat?.title.contains("$6.00") ?? false, "title was: \(bloat?.title ?? "nil")")
    }

    func testContextBloatNotFiredBelowDollarFloor() {
        // 4M opus taxable cache-read → $2.00, under the $5 absolute floor → suppressed.
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                        usage: TokenUsage(cacheRead: 4_000_000), cost: 1.0)
        d.taxableCacheRead["opus"] = 4_000_000
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertFalse(insights.contains { $0.id == "context_bloat" })
    }

    func testContextBloatNotFiredBelowProportionalFloor() {
        // $6 recoverable clears the $5 floor but is under 5% of a $210 week → suppressed.
        let now = Date()
        var aggs = uniformAggs(perDay: 30.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                        usage: TokenUsage(cacheRead: 12_000_000), cost: 30.0)
        d.taxableCacheRead["opus"] = 12_000_000
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertFalse(insights.contains { $0.id == "context_bloat" })
    }

    func testContextBloatDetailNamesTopProject() {
        // Two projects with tax; proj-b carries more → detail should name it.
        let now = Date()
        var aggs = uniformAggs(perDay: 1.0, now: now)
        let day = DayBucket.day(daysAgo: 1, from: now)
        var d = DailyAggregate(day: day)
        d.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                        usage: TokenUsage(cacheRead: 12_000_000), cost: 1.0)
        d.taxableCacheRead["opus"] = 12_000_000
        d.perProject["-Users-me-git-proj-a"] = ProjectUsage(taxableCacheRead: ["opus": 3_000_000])
        d.perProject["-Users-me-git-proj-b"] = ProjectUsage(taxableCacheRead: ["opus": 9_000_000])
        aggs[day] = d
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        let bloat = insights.first { $0.id == "context_bloat" }
        XCTAssertNotNil(bloat)
        XCTAssertTrue(bloat?.detail.contains("proj-b") ?? false,
                      "Expected the detail to name the top-tax project proj-b")
    }

    /// End-to-end: raw records → Aggregator.fold → detect. Every other context_bloat test
    /// hand-sets `taxableCacheRead`, bypassing the fold — but the fold is exactly the seam
    /// that broke in production (a new fold-time field left empty because deduped IDs are
    /// never re-folded). This exercises the whole pipeline so a regression there is caught.
    func testContextBloatEndToEndFromFoldedRecords() {
        let now = Date()
        let projectDir = "-Users-me-git-bloaty"
        var aggs: [String: DailyAggregate] = [:]

        // One opus turn per day across the 7-day window, each re-reading 2M cached tokens with a
        // whole-turn context above the 200K cap. With input/writes = 0, taxable = cacheRead - cap
        // = 1.8M/day → 12.6M over 7 days → priced at opus $0.50/1M = $6.30 recoverable.
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            let rec = UsageRecord(
                id: "msg-\(i)", day: day, model: "opus", rawModel: "claude-opus-4-8",
                usage: TokenUsage(cacheRead: 2_000_000), projectDir: projectDir
            )
            Aggregator.fold(records: [rec], into: &aggs, pricing: .default)
        }

        // Sanity: the fold populated the taxable field (the regression left this empty).
        let foldedTaxable = aggs.values.reduce(0) { $0 + ($1.taxableCacheRead["opus"] ?? 0) }
        XCTAssertEqual(foldedTaxable, 12_600_000, "fold should accumulate taxable cache-read tokens")

        let insights = PatternDetector.detect(aggregates: aggs, pricing: .default, now: now)
        let bloat = insights.first { $0.id == "context_bloat" }
        XCTAssertNotNil(bloat, "context_bloat should fire from folded records, not just hand-set tokens")
        XCTAssertTrue(bloat?.title.contains("$6.30") ?? false, "title was: \(bloat?.title ?? "nil")")
        XCTAssertTrue(bloat?.detail.contains("bloaty") ?? false,
                      "per-project taxable fold should let the detail name the top project: \(bloat?.detail ?? "nil")")
    }

    // MARK: - Burnrate projection

    func testBurnrateDetectedWhenProjectedHighEnough() {
        // Use a fixed reference date well inside a month so we can control day-of-month.
        // 2026-06-15 = day 15 of June (30-day month), 15 days remaining.
        // medianDaily = $0.50/day → projected = MTD + 15*0.50
        // We set MTD = $7.50 → projected = $7.50 + $7.50 = $15 ≥ $10 threshold.
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2026
        components.month = 6
        components.day = 15
        let now = Calendar.current.date(from: components) ?? Date()

        var aggs: [String: DailyAggregate] = [:]
        // 7 days of history (days 8–14 ago in terms of offset but let's use daysAgo from now)
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 0.50)
            aggs[day] = d
        }
        // MTD spend (days 1–14 of June 2026 = 14 days before "today" of June 15)
        // Already covered by the 7-day history above (days 1..7). Add days 8..14:
        for i in 8...14 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6",
                                               usage: TokenUsage(), cost: 0.50)
            aggs[day] = d
        }

        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "burnrate" }, "Expected burnrate insight at $0.50/day median")
    }

    // MARK: - tipsToNotify

    func testTipsToNotifyFiresOnFirstOccurrence() {
        let insights = [PatternInsight(id: "opus_heavy", kind: .bad, title: "", detail: "")]
        let ids = PatternDetector.tipsToNotify(insights: insights, lastTipDay: [:], today: "2026-06-20")
        XCTAssertEqual(ids, ["opus_heavy"])
    }

    func testTipsToNotifyRespectsCadence() {
        // opus_heavy cadence = 7 days; last fired 3 days ago → should NOT fire
        let insights = [PatternInsight(id: "opus_heavy", kind: .bad, title: "", detail: "")]
        let now = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()
        let lastDay = DayBucket.localDay(from: now)
        let ids = PatternDetector.tipsToNotify(
            insights: insights, lastTipDay: ["opus_heavy": lastDay], today: "2026-06-20")
        XCTAssertTrue(ids.isEmpty, "Should not re-fire within cadence window")
    }

    func testTipsToNotifyFiresAfterCadence() {
        // opus_heavy cadence = 7 days; last fired 8 days ago → should fire
        let insights = [PatternInsight(id: "opus_heavy", kind: .bad, title: "", detail: "")]
        let now = Date()
        let eightDaysAgo = DayBucket.day(daysAgo: 8, from: now)
        let ids = PatternDetector.tipsToNotify(
            insights: insights, lastTipDay: ["opus_heavy": eightDaysAgo], today: "2026-06-20", now: now)
        XCTAssertEqual(ids, ["opus_heavy"])
    }

    func testTipsToNotifyIgnoresGoodInsights() {
        let insights = [PatternInsight(id: "cache_high", kind: .good, title: "", detail: "")]
        let ids = PatternDetector.tipsToNotify(insights: insights, lastTipDay: [:], today: "2026-06-20")
        XCTAssertTrue(ids.isEmpty)
    }

    func testTipsToNotifyHandlesUnknownIdGracefully() {
        // An insight with an ID not in notificationCadence should be silently suppressed (MISS-2 guard).
        let insights = [PatternInsight(id: "future_pattern_xyz", kind: .bad, title: "", detail: "")]
        let ids = PatternDetector.tipsToNotify(insights: insights, lastTipDay: [:], today: "2026-06-20")
        XCTAssertTrue(ids.isEmpty, "Unknown cadence IDs should be suppressed, not crash or fire unbounded")
    }

    // MARK: - Parallelism insight

    func testParallelismInsightFiredForTwoSessions() {
        let stats = ConcurrencyStats(peakUserSessions: 2, peakSubagents: 0, peakProjectNames: ["proj-a", "proj-b"])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        XCTAssertTrue(insights.contains { $0.id == "parallelism" })
    }

    func testParallelismInsightFiredForThreeSessions() {
        let stats = ConcurrencyStats(peakUserSessions: 3, peakSubagents: 0, peakProjectNames: ["a", "b", "c"])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        XCTAssertTrue(insights.contains { $0.id == "parallelism" })
    }

    func testParallelismInsightSuppressedForSingleSession() {
        let stats = ConcurrencyStats(peakUserSessions: 1, peakSubagents: 0, peakProjectNames: ["proj-a"])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        XCTAssertFalse(insights.contains { $0.id == "parallelism" })
    }

    func testParallelismInsightSuppressedWhenNoSessions() {
        let insights = PatternDetector.detect(aggregates: [:], concurrency: ConcurrencyStats())
        XCTAssertFalse(insights.contains { $0.id == "parallelism" })
    }

    func testParallelismInsightIsGoodKind() {
        let stats = ConcurrencyStats(peakUserSessions: 2, peakSubagents: 0, peakProjectNames: [])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        let insight = insights.first { $0.id == "parallelism" }
        XCTAssertEqual(insight?.kind, .good)
    }

    func testParallelismInsightFiresEvenWithLowSpend() {
        // Parallelism is before the $0.50 cost guard — it should fire regardless of cost.
        let aggs: [String: DailyAggregate] = [:]
        let stats = ConcurrencyStats(peakUserSessions: 2, peakSubagents: 0, peakProjectNames: [])
        let insights = PatternDetector.detect(aggregates: aggs, concurrency: stats)
        XCTAssertTrue(insights.contains { $0.id == "parallelism" })
    }

    func testParallelismTitleIncludesAgentCountWhenHigh() {
        // When peakSubagents >= 3 the title should mention agents.
        let stats = ConcurrencyStats(peakUserSessions: 3, peakSubagents: 8, peakProjectNames: ["a", "b", "c"])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        let insight = insights.first { $0.id == "parallelism" }
        XCTAssertNotNil(insight)
        XCTAssertTrue(insight!.title.contains("8"), "Title should mention agent count: \(insight!.title)")
    }

    func testParallelismTitleMentionsSessionCount() {
        let stats = ConcurrencyStats(peakUserSessions: 3, peakSubagents: 0, peakProjectNames: [])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        let insight = insights.first { $0.id == "parallelism" }
        XCTAssertTrue(insight!.title.contains("3"), "Title should mention session count: \(insight!.title)")
    }

    func testParallelismNotInTipsToNotify() {
        // Parallelism is .good — it must never trigger a notification.
        let stats = ConcurrencyStats(peakUserSessions: 3, peakSubagents: 8, peakProjectNames: [])
        let insights = PatternDetector.detect(aggregates: [:], concurrency: stats)
        let ids = PatternDetector.tipsToNotify(insights: insights, lastTipDay: [:], today: "2026-07-01")
        XCTAssertFalse(ids.contains("parallelism"))
    }

    // MARK: - Burnrate: new-month suppression

    func testBurnrateSuppressedOnDay1() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2026; components.month = 7; components.day = 1
        let now = Calendar.current.date(from: components)!

        var aggs = uniformAggs(perDay: 50.0, from: 1, count: 14, now: now)
        // Add a "today" entry so there's MTD spend.
        let today = DayBucket.localDay(from: now)
        var d = DailyAggregate(day: today)
        d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 50.0)
        aggs[today] = d

        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertFalse(insights.contains { $0.id == "burnrate" }, "burnrate should be suppressed on day 1 of month")
    }

    func testBurnrateSuppressedOnDay2() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2026; components.month = 7; components.day = 2
        let now = Calendar.current.date(from: components)!

        let aggs = uniformAggs(perDay: 50.0, from: 1, count: 14, now: now)
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertFalse(insights.contains { $0.id == "burnrate" }, "burnrate should be suppressed on day 2 of month")
    }

    func testBurnrateFiresOnDay3WithSufficientSpend() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2026; components.month = 7; components.day = 3
        let now = Calendar.current.date(from: components)!

        // 3 days at $50/day → avgDaily = $50, daysRemaining = 28, projected = $150 + $1400 = $1550
        let aggs = uniformAggs(perDay: 50.0, from: 1, count: 14, now: now)
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        XCTAssertTrue(insights.contains { $0.id == "burnrate" }, "burnrate should fire on day 3 with high enough spend")
    }

    func testBurnrateUsesCurrentMonthAverageNotLastSevenDays() {
        // July 3 with low July spend but heavy June history — should project based on July avg, not June.
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.year = 2026; components.month = 7; components.day = 3
        let now = Calendar.current.date(from: components)!

        var aggs: [String: DailyAggregate] = [:]
        // Heavy June spending (daysAgo 4–10 from July 3 = late June)
        for i in 4...10 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 200.0)
            aggs[day] = d
        }
        // Light July spending: days 1–2 (daysAgo 1–2 from July 3 = July 1–2)
        for i in 1...2 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 1.0)
            aggs[day] = d
        }

        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        let burnrate = insights.first { $0.id == "burnrate" }
        // July MTD = $2 over 3 days → avgDaily = $0.67 → projected = $2 + 28*$0.67 ≈ $20.7
        // Detail should mention ~$0.67/day, NOT the $200/day June rate
        XCTAssertNotNil(burnrate)
        XCTAssertFalse(burnrate!.detail.contains("200"), "Projection should use July avg, not June's $200/day: \(burnrate!.detail)")
    }

    // MARK: - Spend trend rounding

    func testSpendSpikePercentageRoundsNotTruncates() {
        // 72.6% increase should display as "73%", not "72%" (Int truncation bug).
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        // last7: $172.60/day → avg = $172.60
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 172.60)
            aggs[day] = d
        }
        // prior7: $100.00/day → avg = $100.00
        // (172.60/100.00 - 1) * 100 = 72.6 → rounds to 73, truncates to 72
        for i in 8...14 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 100.0)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        let spike = insights.first { $0.id == "spend_spike" }
        XCTAssertNotNil(spike)
        XCTAssertTrue(spike!.title.contains("73%"), "Expected rounded 73%, got: \(spike!.title)")
        XCTAssertFalse(spike!.title.contains("72%"), "Should not truncate to 72%: \(spike!.title)")
    }

    func testSpendDownPercentageRoundsNotTruncates() {
        // 72.6% decrease should display as "73%", not "72%".
        let now = Date()
        var aggs: [String: DailyAggregate] = [:]
        // last7: $27.40/day (down from $100)
        // (1 - 27.40/100.00) * 100 = 72.6 → rounds to 73
        for i in 1...7 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 27.40)
            aggs[day] = d
        }
        for i in 8...14 {
            let day = DayBucket.day(daysAgo: i, from: now)
            var d = DailyAggregate(day: day)
            d.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-4-6", usage: TokenUsage(), cost: 100.0)
            aggs[day] = d
        }
        let insights = PatternDetector.detect(aggregates: aggs, now: now)
        let down = insights.first { $0.id == "spend_down" }
        XCTAssertNotNil(down)
        XCTAssertTrue(down!.title.contains("73%"), "Expected rounded 73%, got: \(down!.title)")
        XCTAssertFalse(down!.title.contains("72%"), "Should not truncate to 72%: \(down!.title)")
    }
}
