import XCTest
@testable import ClaudeOMeter

final class SolPatternTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let solProject = "-Users-test-git-sol-project"

    private func shortRequestAggregates(rawModel: String) -> [String: DailyAggregate] {
        let day = DayBucket.day(daysAgo: 1, from: now)
        // Each 250K prompt is short-context. Its 50K avoidable slice sums to 50M for the day.
        let records = (0..<1_000).map { index in
            UsageRecord(id: "sol-pattern-\(index)", day: day, hour: 0,
                        model: "sol", rawModel: rawModel,
                        usage: TokenUsage(cacheRead: 250_000), projectDir: solProject)
        }
        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: records, into: &aggregates, pricing: .default)
        return aggregates
    }

    func testContextBloatPricesSummedShortRequestsAtShortContextRate() throws {
        for rawModel in ["bedrock_mantle/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[1m]"] {
            let aggregates = shortRequestAggregates(rawModel: rawModel)
            let day = DayBucket.day(daysAgo: 1, from: now)
            let aggregate = try XCTUnwrap(aggregates[day])
            XCTAssertEqual(aggregate.taxableCacheRead["sol"], 50_000_000)
            XCTAssertEqual(aggregate.perProject[solProject]?.taxableCacheRead["sol"], 50_000_000)
            XCTAssertEqual(aggregate.totalCost, 27.50, accuracy: 0.000_001)

            let insight = try XCTUnwrap(PatternDetector.detect(aggregates: aggregates, now: now)
                .first { $0.id == "context_bloat" })
            // 50M × $0.11/M = $5.50, not the $11 from treating the sum as one long prompt.
            XCTAssertEqual(insight.title, "~$5.50 recoverable from context bloat", rawModel)
            XCTAssertTrue(insight.detail.contains("paid ~$5.50"), insight.detail)
            XCTAssertTrue(insight.detail.contains("Most of it is in Users-test-git-sol-project."), insight.detail)
        }
    }

    func testTopProjectRanksConservativeSolEstimateAgainstAnthropic() throws {
        var aggregates = shortRequestAggregates(rawModel: "bedrock_mantle/openai.gpt-6.1-sol[1m]")
        let day = DayBucket.day(daysAgo: 1, from: now)
        var aggregate = try XCTUnwrap(aggregates[day])
        aggregate.perModel["sonnet"] = ModelUsage(
            model: "sonnet", rawModel: "claude-sonnet-4-6",
            usage: TokenUsage(cacheRead: 20_000_000), cost: 20)
        aggregate.taxableCacheRead["sonnet"] = 20_000_000
        aggregate.perProject["-Users-test-git-sonnet-project"] = ProjectUsage(
            taxableCacheRead: ["sonnet": 20_000_000])
        aggregates[day] = aggregate

        let insight = try XCTUnwrap(PatternDetector.detect(aggregates: aggregates, now: now)
            .first { $0.id == "context_bloat" })
        // Sol's $5.50 estimate is below Sonnet's $6, even though Sol has more taxable tokens.
        XCTAssertEqual(insight.title, "~$11.50 recoverable from context bloat")
        XCTAssertTrue(insight.detail.contains("Most of it is in Users-test-git-sonnet-project."), insight.detail)
        XCTAssertFalse(insight.detail.contains("Most of it is in Users-test-git-sol-project."), insight.detail)
    }
}
