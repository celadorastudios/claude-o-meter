import Foundation
import XCTest
@testable import ClaudeOMeter

/// Claude Haiku 5.5 direct, global and US rates. A request whose prompt is over 100,000 tokens
/// uses the long-context tier. Official sources:
/// https://platform.claude.com/docs/en/about-claude/pricing#long-context-pricing and
/// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-5-5.html
final class HaikuPricingTests: XCTestCase {
    private let direct = "claude-haiku-5-5"
    private let global = "global.anthropic.claude-haiku-5-5"
    private let us = "us.anthropic.claude-haiku-5-5"
    private let day = "2026-11-09"

    private func cost(_ usage: TokenUsage, _ rawModel: String, promptTokens: Int? = nil) -> Double {
        PricingTable.default.cost(of: usage, family: ModelNormalizer.family(for: rawModel),
                                  rawModel: rawModel, promptTokens: promptTokens)
    }

    private func fold(_ records: [UsageRecord]) -> DailyAggregate? {
        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: records, into: &aggregates, pricing: PricingTable.default)
        return aggregates[day]
    }

    private func record(_ id: String, _ rawModel: String, _ usage: TokenUsage,
                        domestic: Bool = false) -> UsageRecord {
        UsageRecord(id: id, day: day, hour: 12, model: "haiku", rawModel: rawModel, usage: usage,
                    projectDir: "project", isFast: false, isDomestic: domestic, rateDayUTC: day)
    }

    // MARK: - Keys, wrapper and case

    func testThreeHaikuFiveFiveKeysResolveThroughWrapperAndCase() {
        // Output is excluded from the threshold, so this bundle uses the short output rate.
        let output = TokenUsage(output: 1_000_000)
        XCTAssertEqual(cost(output, direct), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cost(output, direct.uppercased()), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cost(output, global), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cost(output, "bedrock/" + global), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cost(output, us), 0.55, accuracy: 1e-9)
        XCTAssertEqual(cost(output, "bedrock/" + us.uppercased()), 0.55, accuracy: 1e-9)
        let input = TokenUsage(input: 100_000)
        XCTAssertEqual(cost(input, direct), 0.01, accuracy: 1e-9)
        XCTAssertEqual(cost(input, "bedrock/" + global), 0.01, accuracy: 1e-9)
        XCTAssertEqual(cost(input, "bedrock/" + us.uppercased()), 0.011, accuracy: 1e-9)
    }

    // MARK: - Whole-request threshold (strict >, all prompt buckets, output excluded)

    func testHundredThousandPromptIsShortAndOneMoreTokenIsLong() {
        // Short: 0.1*0.04 + 0.01*0.02 + 0.125*0.02 + 0.2*0.02 + 0.5*1 = 0.5107
        let short = TokenUsage(input: 40_000, output: 1_000_000, cacheRead: 20_000,
                               cacheWrite5m: 20_000, cacheWrite1h: 20_000)
        XCTAssertEqual(short.promptTokens, 100_000)
        XCTAssertEqual(cost(short, direct), 0.5107, accuracy: 1e-9)
        // Long: 0.5*0.040001 + 0.05*0.02 + 0.625*0.02 + 1*0.02 + 2.5*1 = 2.5535005
        let long = TokenUsage(input: 40_001, output: 1_000_000, cacheRead: 20_000,
                              cacheWrite5m: 20_000, cacheWrite1h: 20_000)
        XCTAssertEqual(long.promptTokens, 100_001)
        XCTAssertEqual(cost(long, direct), 2.5535005, accuracy: 1e-9)
    }

    func testMixedCacheBucketsCountTowardThresholdButOutputDoesNot() {
        // Output of 900k does not move a 100k prompt over the threshold.
        let outputHeavy = TokenUsage(input: 50_000, output: 900_000, cacheRead: 50_000)
        // 0.1*0.05 + 0.01*0.05 + 0.5*0.9 = 0.4555
        XCTAssertEqual(cost(outputHeavy, direct), 0.4555, accuracy: 1e-9)
        // Cache writes count: 10k + 30k + 30k + 30k = 100k short; the extra write token makes it long.
        let short = TokenUsage(input: 10_000, cacheRead: 30_000, cacheWrite5m: 30_000, cacheWrite1h: 30_000)
        XCTAssertEqual(cost(short, direct), 0.01105, accuracy: 1e-9)
        let long = TokenUsage(input: 10_000, cacheRead: 30_000, cacheWrite5m: 30_000, cacheWrite1h: 30_001)
        XCTAssertEqual(cost(long, direct), 0.055251, accuracy: 1e-9)
    }

    func testFiveMinuteAndOneHourWritesUseDistinctTariffs() {
        let fiveMinute = TokenUsage(cacheWrite5m: 1_000_000)
        let oneHour = TokenUsage(cacheWrite1h: 1_000_000)
        // Each write bucket is 1M tokens, so the prompt is passed explicitly for the short and long cases.
        XCTAssertEqual(cost(fiveMinute, direct, promptTokens: 100_000), 0.125, accuracy: 1e-9)
        XCTAssertEqual(cost(oneHour, direct, promptTokens: 100_000), 0.2, accuracy: 1e-9)
        XCTAssertEqual(cost(fiveMinute, direct, promptTokens: 100_001), 0.625, accuracy: 1e-9)
        XCTAssertEqual(cost(oneHour, direct, promptTokens: 100_001), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cost(fiveMinute, us, promptTokens: 100_000), 0.1375, accuracy: 1e-9)
        XCTAssertEqual(cost(oneHour, us, promptTokens: 100_000), 0.22, accuracy: 1e-9)
        XCTAssertEqual(cost(fiveMinute, us, promptTokens: 100_001), 0.6875, accuracy: 1e-9)
        XCTAssertEqual(cost(oneHour, us, promptTokens: 100_001), 1.1, accuracy: 1e-9)
    }

    func testExplicitPromptTokensDecidesTierForGroupedUsage() {
        // A grouped bundle of short requests: each request had a 50k prompt, so the sum is 1M.
        let grouped = TokenUsage(input: 1_000_000)
        XCTAssertEqual(cost(grouped, direct, promptTokens: 50_000), 0.1, accuracy: 1e-9)
        XCTAssertEqual(cost(grouped, direct, promptTokens: 100_001), 0.5, accuracy: 1e-9)
        // Without the explicit value the summed prompt (1M) decides, so the long tier applies.
        XCTAssertEqual(cost(grouped, direct), 0.5, accuracy: 1e-9)
    }

    // MARK: - Domestic surcharge (fold)

    func testDirectDomesticRequestPaysUSMultiplierOnceInEachTier() {
        // Short: 100k input at 0.1 is 0.01, times 1.1 is 0.011, surcharge 0.001.
        let short = fold([record("short", direct, TokenUsage(input: 100_000), domestic: true)])
        XCTAssertEqual(short?.perModel["haiku"]?.cost ?? -1, 0.011, accuracy: 1e-9)
        XCTAssertEqual(short?.perModel["haiku"]?.surchargeUSD ?? -1, 0.001, accuracy: 1e-9)
        // Long: 1M prompt is over 100k, so 1M input at 0.5 is 0.5, times 1.1 is 0.55 (multiplier once), surcharge 0.05.
        let long = fold([record("long", direct, TokenUsage(input: 1_000_000), domestic: true)])
        XCTAssertEqual(long?.perModel["haiku"]?.cost ?? -1, 0.55, accuracy: 1e-9)
        XCTAssertEqual(long?.perModel["haiku"]?.surchargeUSD ?? -1, 0.05, accuracy: 1e-9)
    }

    func testUSRouteDoesNotAddDomesticSurchargeOnTopOfItsRegionalRates() {
        // The us.anthropic route already carries the regional premium, so the flag adds nothing.
        let short = fold([record("short", us, TokenUsage(input: 100_000), domestic: true)])
        XCTAssertEqual(short?.perModel["haiku"]?.cost ?? -1, 0.011, accuracy: 1e-9)
        XCTAssertEqual(short?.perModel["haiku"]?.surchargeUSD ?? -1, 0, accuracy: 1e-9)
        let long = fold([record("long", us, TokenUsage(input: 1_000_000), domestic: true)])
        XCTAssertEqual(long?.perModel["haiku"]?.cost ?? -1, 0.55, accuracy: 1e-9)
        XCTAssertEqual(long?.perModel["haiku"]?.surchargeUSD ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: - Discount, web search and synthetic

    func testDiscountAppliesAfterTierAndWebSearchIsAddedBeforeIt() {
        var pricing = PricingTable.default
        pricing.discountPercent = 10
        // Short: (100k * 0.1 + 2 * 0.01) * 0.9 = 0.027
        let short = TokenUsage(input: 100_000, webSearchRequests: 2)
        XCTAssertEqual(pricing.cost(of: short, family: "haiku", rawModel: direct), 0.027, accuracy: 1e-9)
        // Long: (1M * 0.5 + 2 * 0.01) * 0.9 = 0.468
        let long = TokenUsage(input: 1_000_000, webSearchRequests: 2)
        XCTAssertEqual(pricing.cost(of: long, family: "haiku", rawModel: direct, promptTokens: 100_001),
                       0.468, accuracy: 1e-9)
    }

    func testSyntheticRecordStaysFree() {
        let synthetic = UsageRecord(id: "synthetic", day: day, hour: 12, model: ModelNormalizer.syntheticFamily,
                                    rawModel: "synthetic", usage: TokenUsage(input: 1_000_000),
                                    projectDir: "project", rateDayUTC: day)
        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: [synthetic], into: &aggregates, pricing: PricingTable.default)
        XCTAssertEqual(aggregates[day]?.perModel[ModelNormalizer.syntheticFamily]?.cost ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: - Unchanged routes

    func testGenericAndOldHaikuRatesAreUnchanged() {
        // Generic family and Haiku 4.5 keep the flat 1.0 input rate, even above 100k tokens.
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(cost(usage, "claude-haiku-4-5"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cost(usage, "claude-haiku-4-5", promptTokens: 100_001), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cost(usage, "claude-haiku-5"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cost(usage, "claude-haiku-5", promptTokens: 100_001), 1.0, accuracy: 1e-9)
    }

    // MARK: - Fold and recost keep original prompt lengths

    func testFoldAndRecostKeepOriginalPromptLengthsForDirectAndWrappedRoutes() {
        // Short request: prompt 100,000. Long request: prompt 101,000 (cache read counts).
        // Short: 0.1 * 0.1 = 0.01. Long: 0.5 * 0.001 + 0.05 * 0.1 = 0.0055. Sum 0.0155.
        for raw in [direct, "bedrock/" + global] {
            let records = [
                record("short", raw, TokenUsage(input: 100_000)),
                record("long", raw, TokenUsage(input: 1_000, cacheRead: 100_000)),
            ]
            var aggregates: [String: DailyAggregate] = [:]
            Aggregator.fold(records: records, into: &aggregates, pricing: PricingTable.default)
            XCTAssertEqual(aggregates[day]?.perModel["haiku"]?.pricingUsage.count, 2, raw)
            XCTAssertEqual(aggregates[day]?.perModel["haiku"]?.cost ?? -1, 0.0155, accuracy: 1e-9, raw)
            XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.0155, accuracy: 1e-9, raw)
            Aggregator.recost(&aggregates, pricing: PricingTable.default)
            XCTAssertEqual(aggregates[day]?.perModel["haiku"]?.cost ?? -1, 0.0155, accuracy: 1e-9, raw)
            XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.0155, accuracy: 1e-9, raw)
        }
    }

    // MARK: - Bundled JSON parity

    func testBundledJSONCarriesVersionSevenAndTheThreeHaikuFiveFiveKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ClaudeOMeter/Resources/pricing.json")
        let table = try JSONDecoder().decode(PricingTable.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.version, 7)
        XCTAssertEqual(table, PricingTable.default)
        for key in [direct, global, us] {
            XCTAssertEqual(table.models[key], PricingTable.default.models[key], key)
            XCTAssertEqual(table.models[key]?.longContextThreshold, 100_000, key)
        }
    }
}
