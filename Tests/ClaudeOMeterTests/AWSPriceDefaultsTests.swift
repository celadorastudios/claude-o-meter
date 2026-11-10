import Foundation
import XCTest
@testable import ClaudeOMeter

/// Bundled Bedrock Sonnet 5.5 defaults: AWS halved the cache-read rate from 2026-10-07 (UTC).
/// Requests before that day, and requests with no usable day, keep the earlier rate.
/// Expected values are literal rates, not read back from the table. The global pre-change read rate (0.20)
/// is the documented 50% cut run backwards, because the global model card does not list it.
final class AWSPriceDefaultsTests: XCTestCase {
    private let usKey = "us.anthropic.claude-sonnet-5-5"
    private let globalKey = "global.anthropic.claude-sonnet-5-5"

    private func cacheReadCost(_ rawModel: String, day: String?) -> Double {
        PricingTable.default.cost(of: TokenUsage(cacheRead: 1_000_000), family: "sonnet",
                                  rawModel: rawModel, rateDayUTC: day)
    }

    func testUSCacheReadIsUnchangedBeforeOctober7() {
        XCTAssertEqual(cacheReadCost(usKey, day: "2026-10-06"), 0.22, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost("bedrock/us.anthropic.claude-sonnet-5-5", day: "2026-10-01"), 0.22, accuracy: 1e-9)
    }

    func testUSCacheReadHalvesFromOctober7Inclusive() {
        XCTAssertEqual(cacheReadCost(usKey, day: "2026-10-07"), 0.11, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost(usKey, day: "2026-10-08"), 0.11, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost(usKey, day: "2026-11-10"), 0.11, accuracy: 1e-9)
    }

    func testGlobalCacheReadIsUnchangedBeforeOctober7AndHalvesFromIt() {
        XCTAssertEqual(cacheReadCost(globalKey, day: "2026-10-06"), 0.20, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost(globalKey, day: "2026-10-07"), 0.10, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost(globalKey, day: "2026-11-10"), 0.10, accuracy: 1e-9)
    }

    func testRevisedUSComponentsAreUnchangedFromOctober7() throws {
        let before = try XCTUnwrap(PricingTable.default.price(forFamily: "sonnet", rawModel: usKey, rateDayUTC: "2026-10-06"))
        let after = try XCTUnwrap(PricingTable.default.price(forFamily: "sonnet", rawModel: usKey, rateDayUTC: "2026-10-07"))
        XCTAssertEqual(before.cacheRead, 0.22)
        XCTAssertEqual(after.cacheRead, 0.11)
        XCTAssertEqual(after.input, 2.2)
        XCTAssertEqual(after.output, 11)
        XCTAssertEqual(after.cacheWrite5m, 2.75)
        XCTAssertEqual(after.cacheWrite1h, 4.4)
        XCTAssertNil(after.longContextThreshold)
        XCTAssertNil(after.longContext)
        XCTAssertNil(after.fastMultiplier)
    }

    func testRevisedGlobalComponentsAreUnchangedFromOctober7() throws {
        let after = try XCTUnwrap(PricingTable.default.price(forFamily: "sonnet", rawModel: globalKey, rateDayUTC: "2026-10-07"))
        XCTAssertEqual(after.input, 2)
        XCTAssertEqual(after.output, 10)
        XCTAssertEqual(after.cacheWrite5m, 2.5)
        XCTAssertEqual(after.cacheWrite1h, 4)
        XCTAssertNil(after.longContextThreshold)
        XCTAssertNil(after.longContext)
        XCTAssertNil(after.fastMultiplier)
    }

    func testMissingOrInvalidDayUsesOldBaseRates() {
        for day in [nil, "", "2026-10-7", "2026-02-30", "2026-13-01"] {
            XCTAssertEqual(cacheReadCost(usKey, day: day), 0.22, accuracy: 1e-9, "US day \(String(describing: day))")
            XCTAssertEqual(cacheReadCost(globalKey, day: day), 0.20, accuracy: 1e-9, "global day \(String(describing: day))")
        }
    }

    func testWrappedBedrockRoutesResolveToTheirRevisedKeys() {
        XCTAssertEqual(cacheReadCost("bedrock/us.anthropic.claude-sonnet-5-5", day: "2026-10-07"), 0.11, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost("bedrock/global.anthropic.claude-sonnet-5-5", day: "2026-10-06"), 0.20, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost("bedrock/global.anthropic.claude-sonnet-5-5", day: "2026-10-07"), 0.10, accuracy: 1e-9)
    }

    func testDirectBareSonnet55KeepsItsTwentyCentReadAfterOctober7() {
        XCTAssertEqual(cacheReadCost("claude-sonnet-5-5", day: "2026-10-06"), 0.20, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost("claude-sonnet-5-5", day: "2026-11-10"), 0.20, accuracy: 1e-9)
    }

    func testGenericSonnetFamilyIsUnchangedAfterOctober7() {
        XCTAssertEqual(cacheReadCost("claude-sonnet-4-6", day: "2026-10-06"), 0.30, accuracy: 1e-9)
        XCTAssertEqual(cacheReadCost("claude-sonnet-4-6", day: "2026-11-10"), 0.30, accuracy: 1e-9)
    }

    func testRegionalSolRoutesKeepTheirBandAndRatesAfterOctober7() throws {
        for route in ["bedrock_mantle/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[1m]"] {
            let price = try XCTUnwrap(PricingTable.default.price(forFamily: "sol", rawModel: route, rateDayUTC: "2026-10-07"))
            XCTAssertEqual(price.longContextThreshold, 272_000)
            XCTAssertEqual(price.cacheRead, 0.11)
            XCTAssertEqual(price.longContext?.cacheRead, 0.22)
            XCTAssertEqual(price.input, 2.2)
            XCTAssertEqual(price.longContext?.input, 4.4)
        }
    }

    func testBundledJSONCarriesVersionSixAndTheSameHistoryAsSwift() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/ClaudeOMeter/Resources/pricing.json")
        let table = try JSONDecoder().decode(PricingTable.self, from: Data(contentsOf: url))
        XCTAssertEqual(table.version, 6)
        XCTAssertEqual(table.modelPriceHistory.map { Set($0.keys) }, Set([usKey, globalKey]))
        XCTAssertEqual(table.modelPriceHistory?[usKey]?.first?.effectiveFrom, "2026-10-07")
        XCTAssertEqual(table.modelPriceHistory?[globalKey]?.first?.effectiveFrom, "2026-10-07")
        XCTAssertEqual(table, PricingTable.default)
    }
}
