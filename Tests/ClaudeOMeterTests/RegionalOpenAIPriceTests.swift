import Foundation
import XCTest
@testable import ClaudeOMeter

/// Prices and the domestic-surcharge exemption for the GPT-6 Luna and Sol Mantle keys and their `[1m]` forms.
final class RegionalOpenAIPriceTests: XCTestCase {
    /// Route, family, then short and long rates as [input, output, cacheRead, cacheWrite] per 1M tokens.
    private let params: [(route: String, family: String, short: [Double], long: [Double])] = [
        ("bedrock_mantle/openai.gpt-6-luna", "luna", [0.11, 0.55, 0.011, 0.1375], [0.22, 0.825, 0.022, 0.275]),
        ("bedrock_mantle/openai.gpt-6-luna[1m]", "luna", [0.11, 0.55, 0.011, 0.1375], [0.22, 0.825, 0.022, 0.275]),
        ("bedrock_mantle/openai.gpt-6-sol", "sol", [2.2, 11, 0.22, 2.75], [4.4, 16.5, 0.44, 5.5]),
        ("bedrock_mantle/openai.gpt-6-sol[1m]", "sol", [2.2, 11, 0.22, 2.75], [4.4, 16.5, 0.44, 5.5]),
    ]

    /// The existing GPT-6.1 Sol routes, which share the domestic exemption with the new keys.
    private let sol61Routes = ["bedrock_mantle/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[1m]"]

    private func cost(_ usage: TokenUsage, _ family: String, _ route: String, promptTokens: Int? = nil) -> Double {
        PricingTable.default.cost(of: usage, family: family, rawModel: route, promptTokens: promptTokens)
    }

    private func assertRates(_ price: ModelPrice?, short s: [Double], long l: [Double],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(price?.input, s[0], file: file, line: line)
        XCTAssertEqual(price?.output, s[1], file: file, line: line)
        XCTAssertEqual(price?.cacheRead, s[2], file: file, line: line)
        XCTAssertEqual(price?.cacheWrite5m, s[3], file: file, line: line)
        XCTAssertEqual(price?.cacheWrite1h, s[3], file: file, line: line)
        XCTAssertEqual(price?.longContextThreshold, 272_000, file: file, line: line)
        XCTAssertEqual(price?.longContext?.input, l[0], file: file, line: line)
        XCTAssertEqual(price?.longContext?.output, l[1], file: file, line: line)
        XCTAssertEqual(price?.longContext?.cacheRead, l[2], file: file, line: line)
        XCTAssertEqual(price?.longContext?.cacheWrite5m, l[3], file: file, line: line)
        XCTAssertEqual(price?.longContext?.cacheWrite1h, l[3], file: file, line: line)
        XCTAssertNil(price?.fastMultiplier, file: file, line: line)
    }

    /// Expected cost from literal rates. Cache writes use one rate, because both buckets share it.
    private func manual(_ u: TokenUsage, _ r: [Double]) -> Double {
        let writes = Double(u.cacheWrite5m + u.cacheWrite1h)
        return (Double(u.input) * r[0] + Double(u.output) * r[1] + Double(u.cacheRead) * r[2] + writes * r[3]) / 1_000_000
    }

    func testLiteralRatesForAllFourKeysAndCase() {
        for p in params {
            for route in [p.route, p.route.uppercased()] {
                XCTAssertEqual(ModelNormalizer.family(for: route), p.family)
                assertRates(PricingTable.default.price(forFamily: p.family, rawModel: route), short: p.short, long: p.long)
            }
        }
    }

    func testThresholdIsStrictAndWholeOutputPriceChanges() {
        for p in params {
            let atLimit = TokenUsage(input: 272_000, output: 1_000_000)
            let over = TokenUsage(input: 272_001, output: 1_000_000)
            XCTAssertEqual(cost(atLimit, p.family, p.route), manual(atLimit, p.short), accuracy: 1e-9)
            XCTAssertEqual(cost(over, p.family, p.route), manual(over, p.long), accuracy: 1e-9)
        }
    }

    func testOutputDoesNotCountTowardThreshold() {
        for p in params {
            let usage = TokenUsage(input: 1_000, output: 2_000_000)
            XCTAssertEqual(cost(usage, p.family, p.route), manual(usage, p.short), accuracy: 1e-9)
        }
    }

    func testMixedFreshAndCacheBucketsSelectBand() {
        for p in params {
            let short = TokenUsage(input: 100_000, output: 1_000, cacheRead: 100_000, cacheWrite5m: 50_000, cacheWrite1h: 22_000)
            let long = TokenUsage(input: 100_000, output: 1_000, cacheRead: 100_000, cacheWrite5m: 50_000, cacheWrite1h: 22_001)
            XCTAssertEqual(cost(short, p.family, p.route), manual(short, p.short), accuracy: 1e-9)
            XCTAssertEqual(cost(long, p.family, p.route), manual(long, p.long), accuracy: 1e-9)
        }
    }

    func testWriteBucketSplitDoesNotChangeCostInEitherTier() {
        let unsplit = TokenUsage(cacheWrite5m: 50_000)
        let split = TokenUsage(cacheWrite5m: 20_000, cacheWrite1h: 30_000)
        for p in params {
            for promptTokens in [272_000, 272_001] {
                XCTAssertEqual(cost(split, p.family, p.route, promptTokens: promptTokens),
                               cost(unsplit, p.family, p.route, promptTokens: promptTokens), accuracy: 1e-9)
            }
        }
    }

    func testSuppliedPromptCountDecidesBandForAggregatedUsage() {
        let summed = TokenUsage(input: 200_000, output: 1_000, cacheRead: 100_000)
        for p in params {
            XCTAssertEqual(cost(summed, p.family, p.route, promptTokens: 272_000), manual(summed, p.short), accuracy: 1e-9)
            XCTAssertEqual(cost(summed, p.family, p.route), manual(summed, p.long), accuracy: 1e-9)
        }
    }

    func testDomesticExemptionCoversAllSixSupportedKeys() {
        for route in params.map(\.route) + sol61Routes {
            for r in [route, route.uppercased()] {
                XCTAssertEqual(PricingTable.default.surchargeMultiplier(family: ModelNormalizer.family(for: r), rawModel: r,
                               isFast: false, isDomestic: true), 1)
            }
        }
    }

    func testDomesticSurchargeStillAppliesToOtherAliasesAndUnknownRegionalModels() {
        var custom = PricingTable.default
        custom.models["custom-sol"] = ModelPrice(input: 1, output: 2, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
        let routes = ["bedrock_mantle/openai.gpt-6-sol[2m]", "openai.gpt-6-sol", "openai/openai.gpt-6-luna",
                      "bedrock/openai.gpt-6-sol", "custom-sol", "bedrock_mantle/openai.gpt-6-unknown"]
        for route in routes {
            XCTAssertEqual(custom.surchargeMultiplier(family: ModelNormalizer.family(for: route), rawModel: route,
                           isFast: false, isDomestic: true), 1.1, accuracy: 1e-9)
        }
    }

    func testCustomFastMultiplierStillAppliesToLongTier() {
        var custom = PricingTable.default
        for p in params {
            custom.models[p.route]?.fastMultiplier = 2
            let over = TokenUsage(input: 272_001, output: 1_000_000)
            let fast = custom.surchargeMultiplier(family: p.family, rawModel: p.route, isFast: true, isDomestic: true)
            XCTAssertEqual(fast, 2, accuracy: 1e-9)
            XCTAssertEqual(custom.cost(of: over, family: p.family, rawModel: p.route), manual(over, p.long), accuracy: 1e-9)
        }
    }

    func testDiscountAndWebSearchApplyToNewKeys() {
        var pricing = PricingTable.default
        pricing.discountPercent = 20
        let usage = TokenUsage(input: 300_000, output: 1_000_000, webSearchRequests: 3)
        for p in params {
            XCTAssertEqual(pricing.cost(of: usage, family: p.family, rawModel: p.route),
                           (manual(usage, p.long) + 0.03) * 0.8, accuracy: 1e-9)
            XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: p.route, promptTokens: 300_000), 0)
        }
    }

    func testBundledJSONMatchesSwiftDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ClaudeOMeter/Resources/pricing.json")
        let table = try JSONDecoder().decode(PricingTable.self, from: Data(contentsOf: url))
        XCTAssertEqual(table, PricingTable.default)
    }

    func testNonMatchingRoutesFallBackAndSol61CacheReadIsUnchanged() {
        for route in ["openai.gpt-6-sol", "bedrock_mantle/openai.gpt-6-sol[2m]", "openai/openai.gpt-6-sol", "bedrock/openai.gpt-6-luna"] {
            let family = ModelNormalizer.family(for: route)
            let price = PricingTable.default.price(forFamily: family, rawModel: route)
            XCTAssertNil(price?.longContextThreshold, route)
            XCTAssertEqual(price?.cacheRead, 0, route)
        }
        XCTAssertEqual(PricingTable.default.price(forFamily: "sol", rawModel: sol61Routes[0])?.cacheRead, 0.11)
    }
}
