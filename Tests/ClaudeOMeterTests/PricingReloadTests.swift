import Foundation
import XCTest
@testable import ClaudeOMeter

final class PricingReloadTests: XCTestCase {
    private let raw = "bedrock_mantle/openai.gpt-6.1-sol"
    private let day = "2026-11-09"
    private let usage = TokenUsage(input: 1_000_000)
    private let rate = ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4)

    /// A snapshot with one model and one project, built by hand. Each holds the retained
    /// `PricingUsageKey` totals that a recost reprices from. `storedCost` is the cost the
    /// snapshot claims before any recost, so a test can tell whether a recost ran.
    private func snapshot(costedWith costed: PricingTable?, version: Int, storedCost: Double = 0) -> Persistence.Snapshot {
        let key = PricingUsageKey(family: "sol", rawModel: raw, rateDayUTC: day,
                                  promptTokens: usage.promptTokens, isFast: false, isDomestic: false)
        var agg = DailyAggregate(day: day)
        agg.perModel["sol"] = ModelUsage(model: "sol", rawModel: raw, usage: usage, cost: storedCost,
                                         perRawModelUsage: [raw: usage],
                                         perRawModelPromptUsage: [raw: [usage.promptTokens: usage]],
                                         pricingUsage: [key: usage])
        agg.perProject["project"] = ProjectUsage(cost: storedCost, perModel: ["sol": storedCost],
                                                 pricingUsage: [key: usage])
        var snap = Persistence.Snapshot()
        snap.aggregates = [day: agg]
        snap.pricingVersion = version
        snap.lastCostedPricing = costed
        return snap
    }

    private func table(version: Int?, rate: ModelPrice? = nil, discount: Double? = nil,
                       history: [DatedModelPrice]? = nil) -> PricingTable {
        var table = PricingTable(models: [raw: rate ?? self.rate], fallback: nil, discountPercent: discount,
                                 version: version, webSearchCost: nil, usOnlyMultiplier: nil)
        table.modelPriceHistory = history.map { [raw: $0] }
        return table
    }

    private func total(_ snap: Persistence.Snapshot) -> Double { snap.aggregates[day]?.totalCost ?? -1 }

    private func projectCost(_ snap: Persistence.Snapshot) -> Double {
        snap.aggregates[day]?.perProject["project"]?.cost ?? -1
    }

    func testMissingMarkerAtSameVersionRecostsAndRecordsTable() {
        var snap = snapshot(costedWith: nil, version: 1)
        let pricing = table(version: 1)
        XCTAssertTrue(UsageStore.recostSnapshot(&snap, pricing: pricing))
        XCTAssertEqual(total(snap), 2.0, accuracy: 1e-12)
        XCTAssertEqual(projectCost(snap), 2.0, accuracy: 1e-12)
        XCTAssertEqual(snap.lastCostedPricing, pricing)
        XCTAssertEqual(snap.pricingVersion, 1)
    }

    func testKnownEqualTableLeavesSnapshotUnchanged() {
        let pricing = table(version: 1)
        var snap = snapshot(costedWith: pricing, version: 1, storedCost: 99)
        XCTAssertFalse(UsageStore.recostSnapshot(&snap, pricing: pricing))
        XCTAssertEqual(total(snap), 99, accuracy: 1e-12)
        XCTAssertEqual(projectCost(snap), 99, accuracy: 1e-12)
        XCTAssertEqual(snap.lastCostedPricing, pricing)
    }

    func testSameVersionEditRepricesForRateDiscountAndHistory() {
        let costed = table(version: 1)
        let revised = ModelPrice(input: 4, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4)
        let edits: [(name: String, pricing: PricingTable, expected: Double)] = [
            ("rate", table(version: 1, rate: ModelPrice(input: 3, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4)), 3.0),
            ("discount", table(version: 1, discount: 50), 1.0),
            ("history", table(version: 1, history: [DatedModelPrice(effectiveFrom: "2026-11-01", price: revised)]), 4.0),
        ]
        for edit in edits {
            var snap = snapshot(costedWith: costed, version: 1, storedCost: 99)
            XCTAssertTrue(UsageStore.recostSnapshot(&snap, pricing: edit.pricing), edit.name)
            XCTAssertEqual(total(snap), edit.expected, accuracy: 1e-12, edit.name)
            XCTAssertEqual(projectCost(snap), edit.expected, accuracy: 1e-12, edit.name)
            XCTAssertEqual(snap.lastCostedPricing, edit.pricing, edit.name)
        }
    }

    func testLowerVersionWithChangedTableRepricesAndAdoptsIt() {
        var snap = snapshot(costedWith: table(version: 5), version: 5, storedCost: 99)
        let lower = table(version: 3, rate: ModelPrice(input: 3, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5, cacheWrite1h: 4))
        XCTAssertTrue(UsageStore.recostSnapshot(&snap, pricing: lower))
        XCTAssertEqual(total(snap), 3.0, accuracy: 1e-12)
        XCTAssertEqual(snap.pricingVersion, 3)
        XCTAssertEqual(snap.lastCostedPricing, lower)
    }

    func testForcedRecostRepricesEqualTableAndRecordsIt() {
        let pricing = table(version: 1)
        var snap = snapshot(costedWith: pricing, version: 1, storedCost: 99)
        XCTAssertTrue(UsageStore.recostSnapshot(&snap, pricing: pricing, force: true))
        XCTAssertEqual(total(snap), 2.0, accuracy: 1e-12)
        XCTAssertEqual(snap.pricingVersion, 1)
        XCTAssertEqual(snap.lastCostedPricing, pricing)
    }

    func testRecordedTableSurvivesSnapshotRoundTrip() throws {
        let pricing = table(version: 2, discount: 10)
        var snap = snapshot(costedWith: nil, version: 0)
        XCTAssertTrue(UsageStore.recostSnapshot(&snap, pricing: pricing))
        let decoded = try JSONDecoder().decode(Persistence.Snapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.lastCostedPricing, pricing)
        XCTAssertFalse(decoded.needsRecost(pricing: pricing))
        XCTAssertEqual(total(decoded), total(snap), accuracy: 1e-12)
    }
}
