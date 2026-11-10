import Foundation
import XCTest
@testable import ClaudeOMeter

final class PricingRecostTests: XCTestCase {
    private let day = "2026-11-09"
    private let raw = "vendor/example-model"

    func testUntieredCustomModelCanGainTierAfterFold() throws {
        let usage = TokenUsage(input: 100_000, output: 400_000, cacheRead: 100_000,
                               cacheWrite5m: 50_000, cacheWrite1h: 50_000)
        var aggregates = fold([record("a", usage: usage)], pricing: table())
        let model = try XCTUnwrap(aggregates[day]?.perModel["unknown"])
        XCTAssertTrue(model.perRawModelPromptUsage.isEmpty)
        XCTAssertEqual(model.pricingUsage[PricingUsageKey(record: record("a", usage: usage))], usage)
        XCTAssertEqual(model.cost, 1.1, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: table(threshold: 200_000))
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 2.2, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 2.2, accuracy: 1e-12)
    }

    func testUnknownUnpricedUsageIsRetainedForLaterExactEntry() throws {
        let usage = TokenUsage(input: 300_000)
        let request = record("a", usage: usage)
        var aggregates = fold([request], pricing: PricingTable(models: [:], fallback: nil))
        XCTAssertEqual(aggregates[day]?.totalCost, 0)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.pricingUsage[PricingUsageKey(record: request)], usage)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.pricingUsage[PricingUsageKey(record: request)], usage)
        Aggregator.recost(&aggregates, pricing: table(threshold: 200_000))
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.6, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.6, accuracy: 1e-12)
    }

    func testIdenticalShortPromptKeysSumCountsWithoutSelectingLongTier() throws {
        let usage = TokenUsage(input: 150_000, output: 500_000)
        var aggregates = fold([record("a", usage: usage), record("b", usage: usage)],
                              pricing: table(threshold: 200_000))
        let model = try XCTUnwrap(aggregates[day]?.perModel["unknown"])
        XCTAssertEqual(model.pricingUsage.count, 1)
        XCTAssertEqual(model.pricingUsage.keys.first?.promptTokens, 150_000)
        XCTAssertEqual(model.pricingUsage.values.first, usage + usage)
        XCTAssertEqual(model.cost, 2.3, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: table(threshold: 200_000))
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 2.3, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.pricingUsage.count, 1)
    }

    func testDistinctUTCDaysWithinOneChartDayKeepTheirOwnRates() throws {
        var pricing = table()
        pricing.modelPriceHistory = [raw: [DatedModelPrice(effectiveFrom: "2026-11-10", price: price(2))]]
        let usage = TokenUsage(input: 100_000)
        var aggregates = fold([
            record("before", usage: usage, rateDayUTC: "2026-11-09"),
            record("after", usage: usage, rateDayUTC: "2026-11-10"),
            record("unknown", usage: usage, rateDayUTC: ""),
        ], pricing: pricing)
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.pricingUsage.count, 3)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.4, accuracy: 1e-12)
        pricing.modelPriceHistory?[raw] = [DatedModelPrice(effectiveFrom: "2026-11-10", price: price(4))]
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.totalCost ?? -1, 0.6, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 0.6, accuracy: 1e-12)
    }

    func testRateDiscountAndDatedFastDomesticEditsRecalculateSurcharge() throws {
        let usage = TokenUsage(input: 100_000, output: 50_000, cacheRead: 100_000,
                               cacheWrite5m: 50_000, cacheWrite1h: 50_000, webSearchRequests: 2)
        var pricing = table(99)
        pricing.modelPriceHistory = [raw: [DatedModelPrice(effectiveFrom: day, price: price(1))]]
        var aggregates = fold([record("a", usage: usage, isFast: true, isDomestic: true)], pricing: pricing)
        let original = try XCTUnwrap(aggregates[day]?.perModel["unknown"])
        XCTAssertEqual(original.cost, 1.98, accuracy: 1e-12)
        XCTAssertEqual(original.surchargeUSD, 1.08, accuracy: 1e-12)
        pricing.discountPercent = 50
        pricing.usOnlyMultiplier = 1.25
        pricing.modelPriceHistory?[raw] = [DatedModelPrice(effectiveFrom: day, price: price(3, fast: 4))]
        Aggregator.recost(&aggregates, pricing: pricing)
        let updated = try XCTUnwrap(aggregates[day]?.perModel["unknown"])
        XCTAssertEqual(updated.cost, 4.25, accuracy: 1e-12)
        XCTAssertEqual(updated.surchargeUSD, 3.4, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost ?? -1, 4.25, accuracy: 1e-12)
        XCTAssertEqual(updated.usage, usage)
    }

    func testProjectsAndProjectlessUsageKeepIndependentFamilyAndRouteCosts() throws {
        let alternate = "vendor/alternate-model"
        let other = "vendor/other-model"
        var pricing = table()
        pricing.models[alternate] = price(2)
        pricing.models[other] = price(1)
        let usage = TokenUsage(input: 100_000)
        var aggregates = fold([
            record("a", usage: usage, project: "A"),
            record("b", usage: usage, family: "beta", rawModel: other, project: "A"),
            record("c", usage: usage, project: "B", isFast: true, isDomestic: true),
            record("d", usage: usage, rawModel: alternate, project: "B"),
            record("e", usage: usage, project: ""),
        ], pricing: pricing)
        XCTAssertNil(aggregates[day]?.perProject[""])
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.pricingUsage.count, 3)
        pricing.models[raw] = price(3)
        pricing.models[alternate] = price(4)
        pricing.models[other] = price(2)
        Aggregator.recost(&aggregates, pricing: pricing)
        let updated = try XCTUnwrap(aggregates[day])
        XCTAssertEqual(updated.totalCost, 1.86, accuracy: 1e-12)
        XCTAssertEqual(updated.perModel["unknown"]?.cost ?? -1, 1.66, accuracy: 1e-12)
        XCTAssertEqual(updated.perModel["beta"]?.cost ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(updated.perProject["A"]?.cost ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(updated.perProject["A"]?.perModel["unknown"] ?? -1, 0.3, accuracy: 1e-12)
        XCTAssertEqual(updated.perProject["A"]?.perModel["beta"] ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(updated.perProject["B"]?.cost ?? -1, 1.06, accuracy: 1e-12)
        XCTAssertEqual(updated.perProject["B"]?.perModel["unknown"] ?? -1, 1.06, accuracy: 1e-12)
    }

    func testRoundTripRecostIsIdempotentAndPreservesTokenAndTaxableCounts() throws {
        let usage = TokenUsage(input: 50_000, output: 20_000, cacheRead: 300_000,
                               cacheWrite5m: 25_000, cacheWrite1h: 25_000, webSearchRequests: 1)
        let original = fold([
            record("a", usage: usage, isFast: true),
            record("b", usage: usage, project: "other", isDomestic: true),
        ], pricing: table())
        let encoded = try JSONEncoder().encode(original)
        var decoded = try JSONDecoder().decode([String: DailyAggregate].self, from: encoded)
        XCTAssertEqual(decoded, original)
        Aggregator.recost(&decoded, pricing: table(3, threshold: 200_000))
        let once = decoded
        Aggregator.recost(&decoded, pricing: table(3, threshold: 200_000))
        XCTAssertEqual(decoded, once)
        XCTAssertEqual(decoded[day]?.totalTokens, original[day]?.totalTokens)
        XCTAssertEqual(decoded[day]?.perModel["unknown"]?.usage, usage + usage)
        XCTAssertEqual(decoded[day]?.perModel["unknown"]?.perRawModelUsage,
                       original[day]?.perModel["unknown"]?.perRawModelUsage)
        XCTAssertEqual(decoded[day]?.perModel["unknown"]?.pricingUsage,
                       original[day]?.perModel["unknown"]?.pricingUsage)
        XCTAssertEqual(decoded[day]?.taxableCacheRead["unknown"], 300_000)
        XCTAssertEqual(decoded[day]?.taxableCacheRead, original[day]?.taxableCacheRead)
        for project in ["project", "other"] {
            XCTAssertEqual(decoded[day]?.perProject[project]?.taxableCacheRead["unknown"], 150_000)
            XCTAssertEqual(decoded[day]?.perProject[project]?.pricingUsage,
                           original[day]?.perProject[project]?.pricingUsage)
        }
    }

    func testSyntheticRequestsStayFreeAndRetainNoPricingKeys() throws {
        let request = record("a", usage: TokenUsage(input: 500_000, output: 500_000,
                                                   cacheRead: 500_000, webSearchRequests: 100),
                             family: ModelNormalizer.syntheticFamily, rawModel: "<synthetic>",
                             isFast: true, isDomestic: true)
        var pricing = table()
        pricing.models["<synthetic>"] = price(1_000, threshold: 1)
        var aggregates = fold([request], pricing: pricing)
        let model = try XCTUnwrap(aggregates[day]?.perModel[ModelNormalizer.syntheticFamily])
        XCTAssertTrue(model.pricingUsage.isEmpty)
        XCTAssertTrue(try XCTUnwrap(aggregates[day]?.perProject["project"]).pricingUsage.isEmpty)
        XCTAssertEqual(model.cost, 0)
        XCTAssertEqual(model.surchargeUSD, 0)
        XCTAssertTrue(try XCTUnwrap(aggregates[day]).taxableCacheRead.isEmpty)
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.totalCost, 0)
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.cost, 0)
    }

    func testSyntheticFirstProjectRetainsRealPricingKeysAndZeroSyntheticFamily() throws {
        let synthetic = record("synthetic", usage: TokenUsage(input: 500_000),
                               family: ModelNormalizer.syntheticFamily, rawModel: "<synthetic>")
        let real = record("real", usage: TokenUsage(input: 100_000))
        var aggregates = fold([synthetic], pricing: table())
        XCTAssertEqual(aggregates[day]?.perProject["project"]?.perModel[ModelNormalizer.syntheticFamily], 0)
        Aggregator.fold(records: [real], into: &aggregates, pricing: table())
        let project = try XCTUnwrap(aggregates[day]?.perProject["project"])
        XCTAssertEqual(project.pricingUsage.count, 1)
        XCTAssertEqual(project.pricingUsage[PricingUsageKey(record: real)], real.usage)
        XCTAssertEqual(project.cost, 0.1, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: table(3))
        let repriced = try XCTUnwrap(aggregates[day]?.perProject["project"])
        XCTAssertEqual(repriced.cost, 0.3, accuracy: 1e-12)
        XCTAssertEqual(repriced.perModel["unknown"] ?? -1, 0.3, accuracy: 1e-12)
        XCTAssertEqual(repriced.perModel[ModelNormalizer.syntheticFamily], 0)
        let once = aggregates
        Aggregator.recost(&aggregates, pricing: table(3))
        XCTAssertEqual(aggregates, once)
        Aggregator.fold(records: [synthetic], into: &aggregates, pricing: table(3))
        Aggregator.recost(&aggregates, pricing: table(3))
        XCTAssertEqual(aggregates[day]?.perProject["project"], repriced)
    }

    func testLegacyModelsUsePromptRemainderAndRawSlicesWhileProjectsKeepDollars() throws {
        let totalUsage = TokenUsage(input: 500_000)
        let bucketUsage = TokenUsage(input: 300_000)
        let alternate = "vendor/alternate-model"
        var pricing = table(3, threshold: 200_000)
        pricing.models[alternate] = price(4)
        var legacyDay = DailyAggregate(day: day)
        legacyDay.perModel["unknown"] = ModelUsage(
            model: "unknown", rawModel: raw, usage: totalUsage + TokenUsage(input: 100_000),
            cost: 10, surchargeUSD: 0.7,
            perRawModelUsage: [raw: totalUsage, alternate: TokenUsage(input: 100_000)],
            perRawModelPromptUsage: [raw: [300_000: bucketUsage]])
        legacyDay.perModel["single"] = ModelUsage(model: "single", rawModel: raw,
                                                 usage: totalUsage, surchargeUSD: 0.1)
        let project = ProjectUsage(cost: 20, perModel: ["unknown": 15, "single": 5],
                                   taxableCacheRead: ["unknown": 123])
        legacyDay.perProject["project"] = project
        var aggregates = [day: legacyDay]
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.cost ?? -1, 3.5, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perModel["single"]?.cost ?? -1, 1.6, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.surchargeUSD, 0.7)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.usage,
                       legacyDay.perModel["unknown"]?.usage)
        XCTAssertEqual(aggregates[day]?.perProject["project"], project)
        let once = aggregates
        Aggregator.recost(&aggregates, pricing: pricing)
        XCTAssertEqual(aggregates, once)
    }

    func testNewFoldIntoLegacyModelAndProjectDoesNotDropEarlierUsage() throws {
        let oldUsage = TokenUsage(input: 200_000)
        let newUsage = TokenUsage(input: 300_000)
        var legacyDay = DailyAggregate(day: day)
        legacyDay.perModel["unknown"] = ModelUsage(
            model: "unknown", rawModel: raw, usage: oldUsage, cost: 0.4, surchargeUSD: 0.2,
            perRawModelUsage: [raw: oldUsage])
        legacyDay.perProject["project"] = ProjectUsage(cost: 0.4, perModel: ["unknown": 0.4])
        var aggregates = [day: legacyDay]
        let pricing = table(threshold: 200_000)
        Aggregator.fold(records: [
            record("new", usage: newUsage, isFast: true, isDomestic: true),
            record("new-project", usage: oldUsage, project: "fresh"),
            record("new-model", usage: oldUsage, family: "fresh", project: "project"),
        ], into: &aggregates, pricing: pricing)
        let model = try XCTUnwrap(aggregates[day]?.perModel["unknown"])
        XCTAssertTrue(model.pricingUsage.isEmpty)
        XCTAssertEqual(model.usage, oldUsage + newUsage + oldUsage)
        XCTAssertEqual(model.perRawModelUsage[raw], oldUsage + newUsage + oldUsage)
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?[300_000], newUsage)
        XCTAssertEqual(model.perRawModelPromptUsage[raw]?[200_000], oldUsage)
        XCTAssertTrue(try XCTUnwrap(aggregates[day]?.perProject["project"]).pricingUsage.isEmpty)
        XCTAssertFalse(try XCTUnwrap(aggregates[day]?.perProject["fresh"]).pricingUsage.isEmpty)
        XCTAssertFalse(try XCTUnwrap(aggregates[day]?.perModel["fresh"]).pricingUsage.isEmpty)
        let legacyProject = aggregates[day]?.perProject["project"]
        XCTAssertEqual(legacyProject?.cost ?? -1, 1.92, accuracy: 1e-12)
        Aggregator.recost(&aggregates, pricing: table(2, threshold: 200_000))
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.cost ?? -1, 2.92, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perModel["unknown"]?.surchargeUSD ?? -1, 0.92, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perModel["fresh"]?.cost ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["fresh"]?.cost ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(aggregates[day]?.perProject["project"], legacyProject)
    }

    func testLegacyDetectionIncludesZeroCostUsageAndStoredDollarFields() throws {
        let request = record("a", usage: TokenUsage(input: 100_000))
        for legacyModel in [
            ModelUsage(model: "unknown", rawModel: raw, usage: TokenUsage(input: 100_000)),
            ModelUsage(model: "unknown", rawModel: raw, cost: 1),
            ModelUsage(model: "unknown", rawModel: raw, surchargeUSD: 1),
        ] {
            var legacyDay = DailyAggregate(day: day)
            legacyDay.perModel["unknown"] = legacyModel
            var aggregates = [day: legacyDay]
            Aggregator.fold(records: [request], into: &aggregates, pricing: table())
            XCTAssertTrue(try XCTUnwrap(aggregates[day]?.perModel["unknown"]).pricingUsage.isEmpty)
        }
        for legacyProject in [ProjectUsage(cost: 1), ProjectUsage(perModel: ["unknown": 0])] {
            var legacyDay = DailyAggregate(day: day)
            legacyDay.perProject["project"] = legacyProject
            var aggregates = [day: legacyDay]
            Aggregator.fold(records: [request], into: &aggregates, pricing: table())
            XCTAssertTrue(try XCTUnwrap(aggregates[day]?.perProject["project"]).pricingUsage.isEmpty)
            let folded = aggregates[day]?.perProject["project"]
            Aggregator.recost(&aggregates, pricing: table(2))
            XCTAssertEqual(aggregates[day]?.perProject["project"], folded)
        }
    }

    private func price(_ rate: Double, fast: Double = 2, threshold: Int? = nil) -> ModelPrice {
        ModelPrice(input: rate, output: rate * 2, cacheRead: rate,
                   cacheWrite5m: rate, cacheWrite1h: rate, fastMultiplier: fast,
                   longContextThreshold: threshold,
                   longContext: threshold == nil ? nil : LongContextPrice(
                    input: rate * 2, output: rate * 4, cacheRead: rate * 2,
                    cacheWrite5m: rate * 2, cacheWrite1h: rate * 2))
    }

    private func table(_ rate: Double = 1, threshold: Int? = nil) -> PricingTable {
        PricingTable(models: [raw: price(rate, threshold: threshold)], fallback: nil,
                     discountPercent: 0, webSearchCost: 0.25, usOnlyMultiplier: 1.1)
    }

    private func record(_ id: String, usage: TokenUsage, family: String = "unknown",
                        rawModel: String? = nil, project: String = "project",
                        rateDayUTC: String = "2026-11-09", isFast: Bool = false,
                        isDomestic: Bool = false) -> UsageRecord {
        UsageRecord(id: id, day: day, hour: 12, model: family, rawModel: rawModel ?? raw,
                    usage: usage, projectDir: project, isFast: isFast, isDomestic: isDomestic,
                    rateDayUTC: rateDayUTC)
    }

    private func fold(_ records: [UsageRecord], pricing: PricingTable) -> [String: DailyAggregate] {
        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: records, into: &aggregates, pricing: pricing)
        return aggregates
    }
}
