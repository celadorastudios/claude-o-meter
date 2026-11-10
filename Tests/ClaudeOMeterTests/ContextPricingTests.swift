import Foundation
import XCTest
@testable import ClaudeOMeter

final class ContextPricingTests: XCTestCase {
    private let raw = "bedrock_mantle/openai.gpt-6.1-sol"
    private let day = "2026-11-09"

    func testDailySumDoesNotSelectLongContextTier() throws {
        let usage = TokenUsage(input: 200_000)
        var aggregates = fold([record("a", usage: usage), record("b", usage: usage)])
        let model = try XCTUnwrap(aggregates[day]?.perModel["sol"])
        XCTAssertEqual(model.usage.input, 400_000)
        XCTAssertEqual(model.perRawModelUsage[raw]?.input, 400_000)
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?[200_000]?.input, 400_000)
        XCTAssertEqual(model.cost, 0.88, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.88, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.88, accuracy: 1e-12)
    }

    func testMixedPromptLengthsAndRawModelsKeepTheirOwnRates() throws {
        let alias = raw + "[1m]"
        let older = "openai.gpt-5.6-sol"
        var aggregates = fold([
            record("a", usage: TokenUsage(input: 200_000)),
            record("b", usage: TokenUsage(input: 300_000)),
            record("c", usage: TokenUsage(input: 300_000), rawModel: alias),
            record("d", usage: TokenUsage(input: 300_000), rawModel: older),
        ])
        let model = try XCTUnwrap(aggregates[day]?.perModel["sol"])
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?.count, 2)
        XCTAssertEqual(model.perRawModelPromptUsage[alias]?.count, 1)
        XCTAssertNil(model.perRawModelPromptUsage[older])
        XCTAssertEqual(model.cost, 4.73, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 4.73, accuracy: 1e-12)
    }

    func testEditedThresholdAndDiscountUseOriginalPrompts() {
        var aggregates = fold([
            record("a", usage: TokenUsage(input: 200_000)),
            record("b", usage: TokenUsage(input: 300_000)),
        ])
        var pricing = PricingTable.default
        pricing.discountPercent = 20
        pricing.models[raw]?.longContextThreshold = 350_000
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 1.10 * 0.8, accuracy: 1e-12)
        pricing.models[raw]?.longContextThreshold = 150_000
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 2.20 * 0.8, accuracy: 1e-12)
    }

    func testPromptLengthIncludesEveryCacheBucketButNotOutput() throws {
        let usage = TokenUsage(input: 100_000, output: 400_000, cacheRead: 80_000,
                               cacheWrite5m: 60_000, cacheWrite1h: 32_000)
        var aggregates = fold([record("a", usage: usage)])
        let model = try XCTUnwrap(aggregates[day]?.perModel["sol"])
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?[272_000], usage)
        XCTAssertEqual(model.cost, 0.22 + 4.4 + 0.0088 + 0.165 + 0.088, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, model.cost, accuracy: 1e-12)
    }

    func testPromptBucketsRoundTripAndOlderSnapshotsDefaultEmpty() throws {
        let original = fold([
            record("a", usage: TokenUsage(input: 200_000)),
            record("b", usage: TokenUsage(input: 300_000)),
        ])
        let data = try JSONEncoder().encode(original)
        var decoded = try JSONDecoder().decode([String: DailyAggregate].self, from: data)
        XCTAssertEqual(decoded, original)
        Aggregator.recost(&decoded, pricing: .default)
        XCTAssertEqual(decoded[day]?.totalCost ?? -1, 1.76, accuracy: 1e-12)

        let older = Data(#"{"model":"sol","rawModel":"openai.gpt-5.6-sol","usage":{"input":100000},"perRawModelUsage":{"openai.gpt-5.6-sol":{"input":100000}}}"#.utf8)
        let olderModel = try JSONDecoder().decode(ModelUsage.self, from: older)
        XCTAssertTrue(olderModel.perRawModelPromptUsage.isEmpty)
        var legacyDay = DailyAggregate(day: day)
        legacyDay.perModel["sol"] = olderModel
        var legacy = [day: legacyDay]
        Aggregator.recost(&legacy, pricing: .default)
        XCTAssertEqual(legacy[day]?.totalCost ?? -1, 0.55, accuracy: 1e-12)
    }

    func testNonTieredAndSyntheticUsageDoNotNeedPromptBuckets() throws {
        var aggregates = fold([
            record("a", usage: TokenUsage(input: 300_000), rawModel: "claude-sonnet-5"),
            record("b", usage: TokenUsage(input: 300_000), rawModel: "<synthetic>"),
        ])
        let sonnet = try XCTUnwrap(aggregates[day]?.perModel["sonnet"])
        let synthetic = try XCTUnwrap(aggregates[day]?.perModel["synthetic"])
        XCTAssertFalse(sonnet.pricingUsage.isEmpty)
        XCTAssertTrue(synthetic.pricingUsage.isEmpty)
        XCTAssertTrue(sonnet.perRawModelPromptUsage.isEmpty)
        XCTAssertTrue(synthetic.perRawModelPromptUsage.isEmpty)
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.6, accuracy: 1e-12)
    }

    func testRecostRecalculatesRecordedSurcharge() throws {
        var aggregates = fold([record("a", usage: TokenUsage(input: 300_000),
                                      rawModel: "claude-sonnet-5", isDomestic: true)])
        let surcharge = try XCTUnwrap(aggregates[day]?.perModel["sonnet"]).surchargeUSD
        XCTAssertEqual(surcharge, 0.06, accuracy: 1e-12)
        XCTAssertGreaterThan(surcharge, 0)
        var pricing = PricingTable.default
        pricing.discountPercent = 50
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.perModel["sonnet"]?.surchargeUSD ?? -1, 0.03, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.33, accuracy: 1e-12)
    }

    func testDisablingTierAfterFirstFoldRetainsNewPromptUsage() throws {
        var aggregates = fold([record("a", usage: TokenUsage(input: 300_000))])
        var pricing = PricingTable.default
        pricing.models[raw]?.longContext = nil
        Aggregator.recost(&aggregates, pricing: pricing)
        Aggregator.fold(records: [record("b", usage: TokenUsage(input: 400_000))],
                        into: &aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 1.54, accuracy: 1e-12)
        let buckets = try XCTUnwrap(aggregates[day]?.perModel["sol"]?.perRawModelPromptUsage[raw])
        XCTAssertEqual(buckets[300_000]?.input, 300_000)
        XCTAssertEqual(buckets[400_000]?.input, 400_000)
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 3.08, accuracy: 1e-12)
    }

    func testInitiallyDisabledTierStillRetainsBundledSolPrompts() throws {
        for route in [raw, raw + "[1m]"] {
            var pricing = PricingTable.default
            pricing.models[route]?.longContext = nil
            pricing.models[route]?.longContextThreshold = nil
            var aggregates = fold([record("a", usage: TokenUsage(input: 300_000), rawModel: route)],
                                  pricing: pricing)
            XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.66, accuracy: 1e-12)
            XCTAssertEqual(aggregates[day]?.perModel["sol"]?.perRawModelPromptUsage[route]?[300_000]?.input,
                           300_000)
            Aggregator.recost(&aggregates, pricing: .default)
            XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 1.32, accuracy: 1e-12)
        }
    }

    func testMissingLegacyPromptBucketsUseShortRatesNotAggregateLength() {
        for hasRawSlices in [false, true] {
            let usage = TokenUsage(input: 600_000)
            var legacyDay = DailyAggregate(day: day)
            legacyDay.perModel["sol"] = ModelUsage(
                model: "sol", rawModel: raw, usage: usage,
                perRawModelUsage: hasRawSlices ? [raw: usage] : [:])
            var aggregates = [day: legacyDay]
            Aggregator.recost(&aggregates, pricing: .default)
            XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 1.32, accuracy: 1e-12)
        }
    }

    func testCustomTierAddedLaterUsesRetainedPromptLengths() {
        let customRaw = "custom-sol"
        let oldUsage = TokenUsage(input: 300_000, output: 100, cacheRead: 200,
                                  cacheWrite5m: 300, cacheWrite1h: 400, webSearchRequests: 1)
        let newUsage = TokenUsage(input: 400_000, output: 200, cacheRead: 300,
                                  cacheWrite5m: 400, cacheWrite1h: 500, webSearchRequests: 2)
        var aggregates = fold([record("a", usage: oldUsage, rawModel: customRaw)])
        var pricing = PricingTable.default
        pricing.models[customRaw] = pricing.models[raw]
        Aggregator.fold(records: [record("b", usage: newUsage, rawModel: customRaw)],
                        into: &aggregates, pricing: pricing)
        Aggregator.recost(&aggregates, pricing: pricing)
        let expected = pricing.cost(of: oldUsage, family: "sol", rawModel: customRaw)
            + pricing.cost(of: newUsage, family: "sol", rawModel: customRaw)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, expected, accuracy: 1e-12)
    }

    func testLegacyUnbucketedRemainderKeepsShortRatesBesideBucketedRequests() throws {
        let oldUsage = TokenUsage(input: 200_000)
        let newUsage = TokenUsage(input: 300_000)
        let combined = oldUsage + newUsage
        var legacyDay = DailyAggregate(day: day)
        legacyDay.perModel["sol"] = ModelUsage(
            model: "sol", rawModel: raw, usage: combined,
            perRawModelUsage: [raw: combined],
            perRawModelPromptUsage: [raw: [300_000: newUsage]])
        var aggregates = [day: legacyDay]
        Aggregator.recost(&aggregates, pricing: .default)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 1.76, accuracy: 1e-12)
        let model = try XCTUnwrap(aggregates[day]?.perModel["sol"])
        XCTAssertEqual(model.usage, combined)
        XCTAssertEqual(model.perRawModelUsage[raw], combined)
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?.count, 1)
        XCTAssertTrue(model.pricingUsage.isEmpty)
    }

    private func record(_ id: String, usage: TokenUsage, rawModel: String? = nil,
                        isDomestic: Bool = false) -> UsageRecord {
        let model = rawModel ?? raw
        return UsageRecord(id: id, day: day, hour: 12, model: ModelNormalizer.family(for: model),
                           rawModel: model, usage: usage, projectDir: "project", isDomestic: isDomestic)
    }

    private func fold(_ records: [UsageRecord], pricing: PricingTable = .default) -> [String: DailyAggregate] {
        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: records, into: &aggregates, pricing: pricing)
        return aggregates
    }
}
