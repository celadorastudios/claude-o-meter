import Foundation
import XCTest
@testable import ClaudeOMeter

/// Dated price revisions: which price applies to a request on a given UTC day.
/// Uses a hypothetical model key so that the tests do not depend on real rate values.
final class DatedPricingTests: XCTestCase {
    private let key = "hypothetical-model"

    private func base() -> ModelPrice {
        ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4)
    }

    private func revision(_ day: String, input: Double, output: Double) -> DatedModelPrice {
        DatedModelPrice(effectiveFrom: day,
                        price: ModelPrice(input: input, output: output, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2))
    }

    private func table(_ history: [DatedModelPrice]) -> PricingTable {
        PricingTable(models: [key: base()], modelPriceHistory: [key: history])
    }

    func testUndatedAndNilDayUseBaseBeforeFirstRevision() {
        let pricing = table([revision("2026-03-01", input: 5, output: 20)])
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key)?.input, 2)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: nil)?.input, 2)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "")?.input, 2)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-02-28")?.input, 2)
    }

    func testRevisionAppliesOnItsDayInclusiveAndUntilTheNext() {
        let pricing = table([revision("2026-03-01", input: 5, output: 20),
                             revision("2026-06-01", input: 7, output: 30)])
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-03-01")?.input, 5)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-05-31")?.input, 5)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-06-01")?.input, 7)
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: key, rateDayUTC: "2030-01-01")?.input, 7)
    }

    func testOutOfOrderHistoryUsesLatestEffectiveRevision() throws {
        let json = #"""
        {"models":{"hypothetical-model":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite5m":2.5,"cacheWrite1h":4}},
         "modelPriceHistory":{"hypothetical-model":[
           {"effectiveFrom":"2026-06-01","price":{"input":7,"output":30,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}},
           {"effectiveFrom":"2026-03-01","price":{"input":5,"output":20,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}}]}}
        """#
        let decoded = try JSONDecoder().decode(PricingTable.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-04-01")?.input, 5)
        XCTAssertEqual(decoded.price(forFamily: "x", rawModel: key, rateDayUTC: "2026-07-01")?.input, 7)
    }

    func testFamilyHistoryDoesNotOverrideExactKeyPrice() {
        let exact = ModelPrice(input: 9, output: 9, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)
        var pricing = PricingTable(models: ["sonnet": base(), "claude-sonnet-5": exact])
        pricing.modelPriceHistory = ["sonnet": [revision("2026-03-01", input: 5, output: 20)]]
        XCTAssertEqual(pricing.price(forFamily: "sonnet", rawModel: "claude-sonnet-5", rateDayUTC: "2026-04-01")?.input, 9)
        XCTAssertEqual(pricing.price(forFamily: "sonnet", rawModel: "claude-sonnet-4-6", rateDayUTC: "2026-04-01")?.input, 5)
    }

    func testRawKeyIsCheckedBeforeStrippedKey() {
        var pricing = PricingTable(models: ["bedrock/us.x": base(), "us.x": ModelPrice(input: 9, output: 9, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)])
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: "bedrock/us.x")?.input, 2)
        pricing.models = ["us.x": base()]
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: "bedrock/us.x")?.input, 2)
        pricing.models = ["us.x": ModelPrice(input: 9, output: 9, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)]
        XCTAssertEqual(pricing.price(forFamily: "x", rawModel: "bedrock/us.x")?.input, 9)
    }

    func testOneRevisionAppliesToShortAndLongPromptsAndAllComponents() {
        let longPrice = LongContextPrice(input: 4, output: 16, cacheRead: 0.4, cacheWrite5m: 5, cacheWrite1h: 8)
        let revised = ModelPrice(input: 3, output: 12, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6,
                                 longContextThreshold: 100_000, longContext: longPrice)
        var pricing = table([])
        pricing.modelPriceHistory = [key: [DatedModelPrice(effectiveFrom: "2026-06-01", price: revised)]]
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                               cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        let short = pricing.cost(of: usage, family: "x", rawModel: key, promptTokens: 100_000, rateDayUTC: "2026-06-02")
        let long = pricing.cost(of: usage, family: "x", rawModel: key, promptTokens: 100_001, rateDayUTC: "2026-06-02")
        XCTAssertEqual(short, 3 + 12 + 0.3 + 3.75 + 6, accuracy: 1e-9)
        XCTAssertEqual(long, 4 + 16 + 0.4 + 5 + 8, accuracy: 1e-9)
        let beforeRevision = pricing.cost(of: usage, family: "x", rawModel: key, promptTokens: 100_001, rateDayUTC: "2026-05-31")
        XCTAssertEqual(beforeRevision, 2 + 10 + 0.2 + 2.5 + 4, accuracy: 1e-9)
    }

    func testRevisedFastMultiplierDrivesSurchargeOnlyForItsDays() {
        var pricing = table([])
        pricing.modelPriceHistory = [key: [DatedModelPrice(effectiveFrom: "2026-06-01",
                                                           price: ModelPrice(input: 2, output: 10, cacheRead: 0.2,
                                                                             cacheWrite5m: 2.5, cacheWrite1h: 4,
                                                                             fastMultiplier: 2))]]
        XCTAssertEqual(pricing.surchargeMultiplier(family: "x", rawModel: key, isFast: true, isDomestic: false), 1, accuracy: 1e-9)
        XCTAssertEqual(pricing.surchargeMultiplier(family: "x", rawModel: key, isFast: true, isDomestic: false,
                                                   rateDayUTC: "2026-05-31"), 1, accuracy: 1e-9)
        XCTAssertEqual(pricing.surchargeMultiplier(family: "x", rawModel: key, isFast: true, isDomestic: false,
                                                   rateDayUTC: "2026-06-01"), 2, accuracy: 1e-9)
    }

    func testDiscountAndWebSearchUseTheRevisionOfTheSameDay() {
        var pricing = table([revision("2026-06-01", input: 5, output: 20)])
        pricing.discountPercent = 20
        pricing.webSearchCost = 0.5
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, webSearchRequests: 2)
        XCTAssertEqual(pricing.cost(of: usage, family: "x", rawModel: key, rateDayUTC: "2026-06-01"),
                       (5 + 20 + 1) * 0.8, accuracy: 1e-9)
        XCTAssertEqual(pricing.cost(of: usage, family: "x", rawModel: key, rateDayUTC: "2026-05-31"),
                       (2 + 10 + 1) * 0.8, accuracy: 1e-9)
    }

    func testSyntheticCostIsZeroOnAnyDay() {
        let pricing = table([revision("2026-06-01", input: 5, output: 20)])
        let usage = TokenUsage(input: 1_000_000)
        XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: "<synthetic>", rateDayUTC: "2026-06-02"), 0)
        XCTAssertEqual(pricing.cost(of: usage, family: "synthetic", rawModel: key, rateDayUTC: "2026-06-02"), 0)
    }

    private let baseJSON = #"{"hypothetical-model":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite5m":2.5,"cacheWrite1h":4}}"#

    private func decodeHistory(_ history: String, models: String? = nil) throws -> PricingTable {
        let modelsJSON = models ?? baseJSON
        let json = #"{"models":"# + modelsJSON + #","modelPriceHistory":"# + history + "}"
        return try JSONDecoder().decode(PricingTable.self, from: Data(json.utf8))
    }

    private let validRevision = #"{"effectiveFrom":"2026-06-01","price":{"input":7,"output":30,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2}}"#

    private let tierJSON = #""longContext":{"input":4,"output":16,"cacheRead":0.4,"cacheWrite5m":5,"cacheWrite1h":8}"#

    private func revisionWith(_ extra: String) -> String {
        #"{"effectiveFrom":"2026-06-01","price":{"input":7,"output":30,"cacheRead":0.1,"cacheWrite5m":1.25,"cacheWrite1h":2,"# + extra + "}}"
    }

    private func decodeOneRevision(_ revision: String) throws -> PricingTable {
        try decodeHistory(#"{"hypothetical-model":["# + revision + "]}")
    }

    func testRejectsMalformedAndImpossibleDates() {
        for day in ["2026-6-01", "2026/06/01", "2026-02-30", "2026-13-01", "26-06-01", "2026-06-01T00:00:00Z", "2026-06-00"] {
            let revision = validRevision.replacingOccurrences(of: "2026-06-01", with: day)
            XCTAssertThrowsError(try decodeHistory(#"{"hypothetical-model":["# + revision + "]}"), day)
        }
    }

    func testAcceptsLeapDayOnlyInLeapYears() throws {
        let leap = validRevision.replacingOccurrences(of: "2026-06-01", with: "2028-02-29")
        XCTAssertNoThrow(try decodeHistory(#"{"hypothetical-model":["# + leap + "]}"))
        let notLeap = validRevision.replacingOccurrences(of: "2026-06-01", with: "2026-02-29")
        XCTAssertThrowsError(try decodeHistory(#"{"hypothetical-model":["# + notLeap + "]}"))
    }

    func testRejectsDuplicateEffectiveDayForOneKey() {
        XCTAssertThrowsError(try decodeHistory(#"{"hypothetical-model":["# + validRevision + "," + validRevision + "]}"))
    }

    func testRejectsHistoryWithoutBaseKey() {
        XCTAssertThrowsError(try decodeHistory(#"{"other-model":["# + validRevision + "]}"))
    }

    func testRejectsUppercaseHistoryKey() {
        let models = #"{"Hypothetical-Model":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite5m":2.5,"cacheWrite1h":4}}"#
        XCTAssertThrowsError(try decodeHistory(#"{"Hypothetical-Model":["# + validRevision + "]}", models: models))
    }

    func testRejectsNegativeRevisedRate() {
        let negative = validRevision.replacingOccurrences(of: "\"input\":7", with: "\"input\":-7")
        XCTAssertThrowsError(try decodeHistory(#"{"hypothetical-model":["# + negative + "]}"))
    }

    func testRejectsNegativeLongContextThresholdButAcceptsZero() {
        XCTAssertNoThrow(try decodeOneRevision(revisionWith(#""longContextThreshold":0,"# + tierJSON)))
        XCTAssertThrowsError(try decodeOneRevision(revisionWith(#""longContextThreshold":-1,"# + tierJSON)))
    }

    func testRejectsUnpairedLongContextFields() {
        XCTAssertThrowsError(try decodeOneRevision(revisionWith(#""longContextThreshold":100000"#)))
        XCTAssertThrowsError(try decodeOneRevision(revisionWith(tierJSON)))
    }

    func testRejectsNegativeLongContextRate() {
        XCTAssertNoThrow(try decodeOneRevision(revisionWith(#""longContextThreshold":100000,"# + tierJSON)))
        let negativeTier = tierJSON.replacingOccurrences(of: "\"input\":4", with: "\"input\":-4")
        XCTAssertThrowsError(try decodeOneRevision(revisionWith(#""longContextThreshold":100000,"# + negativeTier)))
    }

    func testTableWithoutHistoryStillDecodesAsBefore() throws {
        let json = #"{"models":{"hypothetical-model":{"input":2,"output":10,"cacheRead":0.2,"cacheWrite5m":2.5,"cacheWrite1h":4}},"fallback":null,"version":5}"#
        let decoded = try JSONDecoder().decode(PricingTable.self, from: Data(json.utf8))
        XCTAssertNil(decoded.modelPriceHistory)
        XCTAssertEqual(decoded.version, 5)
    }
}
