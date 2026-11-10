import Foundation
import XCTest
@testable import ClaudeOMeter

final class PricingUsageTests: XCTestCase {
    private let raw = "bedrock_mantle/openai.gpt-6.1-sol"
    private let alias = "bedrock_mantle/openai.gpt-6.1-sol[1m]"

    func testPricingUsageRoundTripsForModelAndProject() throws {
        let key = PricingUsageKey(family: "sol", rawModel: raw, rateDayUTC: "2026-11-09",
                                  promptTokens: 300_000, isFast: true, isDomestic: true)
        let usage = TokenUsage(input: 1, output: 2, cacheRead: 3, cacheWrite5m: 4,
                               cacheWrite1h: 5, webSearchRequests: 6)
        var model = ModelUsage(model: "sol", rawModel: raw, usage: usage)
        model.pricingUsage[key] = usage
        var project = ProjectUsage(cost: 1.5, perModel: ["sol": 1.5])
        project.pricingUsage[key] = usage
        var day = DailyAggregate(day: "2026-11-09")
        day.perModel["sol"] = model
        day.perProject["project"] = project

        let data = try JSONEncoder().encode(day)
        let decoded = try JSONDecoder().decode(DailyAggregate.self, from: data)
        XCTAssertEqual(decoded, day)
        XCTAssertEqual(decoded.perModel["sol"]?.pricingUsage[key], usage)
        XCTAssertEqual(decoded.perProject["project"]?.pricingUsage[key], usage)
    }

    func testEquivalentKeysMergeIntoOneBucket() {
        // Same prompt length and flags, different output and record IDs: one bucket.
        let records = [
            record(id: "a", usage: TokenUsage(input: 200_000, output: 10)),
            record(id: "b", usage: TokenUsage(input: 200_000, output: 20)),
        ]
        var buckets: [PricingUsageKey: TokenUsage] = [:]
        for r in records {
            let key = PricingUsageKey(record: r)
            buckets[key] = (buckets[key] ?? TokenUsage()) + r.usage
        }
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.values.first?.output, 30)
        XCTAssertEqual(buckets.values.first?.input, 400_000)
    }

    func testEachPricingInputSeparatesKeys() {
        let base = PricingUsageKey(record: record())
        let keys: [PricingUsageKey] = [
            base,
            PricingUsageKey(record: record(rateDayUTC: "2026-11-10")),
            PricingUsageKey(record: record(usage: TokenUsage(input: 200_001))),
            PricingUsageKey(record: record(rawModel: alias)),
            PricingUsageKey(record: record(rawModel: "claude-sonnet-5")),
            PricingUsageKey(record: record(isFast: true)),
            PricingUsageKey(record: record(isDomestic: true)),
            PricingUsageKey(family: "opus", rawModel: raw, rateDayUTC: "2026-11-09",
                            promptTokens: 200_000, isFast: false, isDomestic: false),
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testLegacyJSONWithoutPricingUsageKeepsExistingTotals() throws {
        let legacy = Data(#"""
        {"day":"2026-11-09",
        "perModel":{"sol":{"model":"sol","rawModel":"\#(raw)","usage":{"input":100000,"output":5},"cost":0.55,"surchargeUSD":0.0}},
        "perProject":{"project":{"cost":0.55,"perModel":{"sol":0.55}}}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(DailyAggregate.self, from: legacy)
        XCTAssertEqual(decoded.perModel["sol"]?.usage.input, 100_000)
        XCTAssertEqual(decoded.perModel["sol"]?.cost ?? -1, 0.55, accuracy: 1e-12)
        XCTAssertEqual(decoded.perProject["project"]?.cost ?? -1, 0.55, accuracy: 1e-12)
        XCTAssertTrue(decoded.perModel["sol"]?.pricingUsage.isEmpty ?? false)
        XCTAssertTrue(decoded.perProject["project"]?.pricingUsage.isEmpty ?? false)
    }

    func testDefaultRateDayIsEmptyNotLocalDay() {
        let usage = record()
        XCTAssertEqual(usage.rateDayUTC, "")
        XCTAssertEqual(usage.day, "2026-11-09")
        XCTAssertEqual(PricingUsageKey(record: usage).rateDayUTC, "")
    }

    func testKeyFromRecordPreservesEveryPricingInput() {
        let r = record(usage: TokenUsage(input: 250_000, cacheRead: 50_000), rawModel: alias,
                       rateDayUTC: "2026-11-08", isFast: true, isDomestic: true)
        let key = PricingUsageKey(record: r)
        XCTAssertEqual(key, PricingUsageKey(family: "sol", rawModel: alias, rateDayUTC: "2026-11-08",
                                            promptTokens: 300_000, isFast: true, isDomestic: true))
    }

    private func record(id: String = "a", usage: TokenUsage = TokenUsage(input: 200_000),
                        rawModel: String? = nil, rateDayUTC: String = "",
                        isFast: Bool = false, isDomestic: Bool = false, hour: Int = 12) -> UsageRecord {
        let model = rawModel ?? raw
        return UsageRecord(id: id, day: "2026-11-09", hour: hour, model: ModelNormalizer.family(for: model),
                           rawModel: model, usage: usage, projectDir: "project",
                           isFast: isFast, isDomestic: isDomestic, rateDayUTC: rateDayUTC)
    }
}
