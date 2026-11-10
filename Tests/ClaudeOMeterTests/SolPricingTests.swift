import Foundation
import XCTest
@testable import ClaudeOMeter

final class SolPricingTests: XCTestCase {
    private let routes = ["bedrock_mantle/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[1m]"]

    func testRegionalRoutesAndCaseUseAllStandardRates() {
        let usage = TokenUsage(input: 10_000, output: 20_000, cacheRead: 30_000,
                               cacheWrite5m: 40_000, cacheWrite1h: 50_000)
        for route in routes + routes.map({ $0.uppercased() }) {
            XCTAssertEqual(ModelNormalizer.family(for: route), "sol")
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: "sol", rawModel: route),
                           0.4928, accuracy: 1e-9)
            let price = PricingTable.default.price(forFamily: "sol", rawModel: route)
            XCTAssertEqual(price?.longContextThreshold, 272_000)
            XCTAssertEqual(price?.cacheWrite1h, 2.75)
            XCTAssertEqual(price?.longContext?.cacheWrite1h, 5.5)
            XCTAssertNil(price?.fastMultiplier)
        }
    }

    func testPositiveOneHourBucketUsesSingleSolWriteTariff() {
        let usage = TokenUsage(cacheWrite1h: 50_000)
        for route in routes {
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: "sol", rawModel: route,
                                                    promptTokens: 272_000), 0.1375, accuracy: 1e-9)
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: "sol", rawModel: route,
                                                    promptTokens: 272_001), 0.275, accuracy: 1e-9)
        }
    }

    func testCacheWriteBucketSplitDoesNotChangeCostInEitherTier() {
        let unsplit = TokenUsage(cacheWrite5m: 50_000)
        let split = TokenUsage(cacheWrite5m: 20_000, cacheWrite1h: 30_000)
        for route in routes {
            for promptTokens in [272_000, 272_001] {
                XCTAssertEqual(PricingTable.default.cost(of: split, family: "sol", rawModel: route,
                                                        promptTokens: promptTokens),
                               PricingTable.default.cost(of: unsplit, family: "sol", rawModel: route,
                                                         promptTokens: promptTokens), accuracy: 1e-9)
            }
        }
    }

    func testThresholdIsStrictAndLongRatesApplyToWholeRequest() {
        for route in routes {
            let short = TokenUsage(input: 272_000, output: 1_000_000)
            let long = TokenUsage(input: 272_001, output: 1_000_000)
            XCTAssertEqual(PricingTable.default.cost(of: short, family: "sol", rawModel: route),
                           0.5984 + 11, accuracy: 1e-9)
            XCTAssertEqual(PricingTable.default.cost(of: long, family: "sol", rawModel: route),
                           1.1968044 + 16.5, accuracy: 1e-9)
        }
    }

    func testEveryCacheBucketCountsTowardPromptThreshold() {
        let short = TokenUsage(input: 2_000, output: 1_000_000, cacheRead: 100_000,
                               cacheWrite5m: 100_000, cacheWrite1h: 70_000)
        var long = short
        long.cacheWrite1h += 1
        let shortWriteCost: Double = 70_000 * 2.75 / 1_000_000
        let longWriteCost: Double = 70_001 * 5.5 / 1_000_000
        for route in routes {
            XCTAssertEqual(PricingTable.default.cost(of: short, family: "sol", rawModel: route),
                           0.0044 + 11 + 0.011 + 0.275 + shortWriteCost, accuracy: 1e-9)
            XCTAssertEqual(PricingTable.default.cost(of: long, family: "sol", rawModel: route),
                           0.0088 + 16.5 + 0.022 + 0.55 + longWriteCost, accuracy: 1e-9)
        }
    }

    func testSuppliedPromptCountKeepsSummedShortUsageInShortTier() {
        let summed = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                                cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        for route in routes {
            XCTAssertEqual(PricingTable.default.cost(of: summed, family: "sol", rawModel: route,
                                                    promptTokens: 272_000), 18.81, accuracy: 1e-9)
            XCTAssertEqual(PricingTable.default.cost(of: summed, family: "sol", rawModel: route,
                                                    promptTokens: 272_001), 32.12, accuracy: 1e-9)
            XCTAssertEqual(PricingTable.default.cost(of: TokenUsage(output: 1_000_000), family: "sol",
                                                    rawModel: route, promptTokens: 272_001), 16.5, accuracy: 1e-9)
        }
    }

    func testLongRequestMatchesAWSConfiguredComparator() {
        let usage = TokenUsage(input: 2, output: 100, cacheRead: 271_000, cacheWrite5m: 1_000)
        for route in routes {
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: "sol", rawModel: route),
                           0.0667788, accuracy: 1e-12)
        }
    }

    func testOtherRoutesAndOldFamiliesKeepExistingPrices() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let unsupported = ["openai.gpt-6.1-sol", "openai.gpt-6.1-sol[1m]", "openai/openai.gpt-6.1-sol",
                           "bedrock/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[2m]",
                           "openai.gpt-5.6-sol", "bedrock_mantle/openai.gpt-5.6-sol"]
        for route in unsupported {
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: "sol", rawModel: route), 38.5, accuracy: 1e-9)
        }
        for (family, route, expected) in [("luna", "openai.gpt-5.6-luna", 7.7),
                                          ("terra", "openai.gpt-5.6-terra", 19.25),
                                          ("sonnet", "claude-sonnet-5", 18.7),
                                          ("sonnet", "bedrock/us.anthropic.claude-sonnet-5", 20.57),
                                          ("unknown", "future-model", 46.75)] {
            XCTAssertEqual(PricingTable.default.cost(of: usage, family: family, rawModel: route), expected, accuracy: 1e-9)
        }
    }

    func testDomesticPremiumGuardIsLimitedToRegionalRawRoutes() {
        for route in routes + routes.map({ $0.uppercased() }) {
            XCTAssertEqual(PricingTable.default.surchargeMultiplier(family: "sol", rawModel: route,
                           isFast: true, isDomestic: true), 1)
        }
        var custom = PricingTable.default
        custom.models["custom-sol"] = ModelPrice(input: 1, output: 2, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
        for route in ["custom-sol", "openai.gpt-6.1-sol", "other/openai.gpt-6.1-sol"] {
            XCTAssertEqual(custom.surchargeMultiplier(family: "sol", rawModel: route,
                           isFast: false, isDomestic: true), 1.1, accuracy: 1e-9)
        }
        XCTAssertEqual(custom.surchargeMultiplier(family: "opus", rawModel: "claude-opus-5-5",
                       isFast: true, isDomestic: true), 2.2, accuracy: 1e-9)
    }

    func testDiscountWebSearchAndSyntheticGuardsRemainIntact() {
        var pricing = PricingTable.default
        pricing.discountPercent = 20
        let usage = TokenUsage(input: 300_000, output: 1_000_000, webSearchRequests: 3)
        for route in routes {
            XCTAssertEqual(pricing.cost(of: usage, family: "sol", rawModel: route), (1.32 + 16.5 + 0.03) * 0.8, accuracy: 1e-9)
            XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: route, promptTokens: 300_000), 0)
        }
        pricing.models = [:]
        pricing.fallback = nil
        XCTAssertEqual(pricing.cost(of: usage, family: "unknown", rawModel: "missing"), 0)
    }

    func testOldPriceDecodesWithoutLongContextFields() throws {
        let json = #"{"input":5.5,"output":33,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0}"#
        let price = try JSONDecoder().decode(ModelPrice.self, from: Data(json.utf8))
        XCTAssertNil(price.longContextThreshold)
        XCTAssertNil(price.longContext)
        XCTAssertNil(price.fastMultiplier)
        let table = PricingTable(models: ["sol": price])
        XCTAssertEqual(table.cost(of: TokenUsage(input: 1_000_000), family: "sol", rawModel: routes[0]), 5.5)
    }

    func testBundledJSONMatchesSwiftDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ClaudeOMeter/Resources/pricing.json")
        let table = try JSONDecoder().decode(PricingTable.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.version, 7)
        XCTAssertEqual(table, PricingTable.default)
    }
}
