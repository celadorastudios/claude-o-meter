import Foundation
import XCTest
@testable import ClaudeOMeter

final class PricingPersistenceTests: XCTestCase {
    /// A fresh temporary directory per test. Tests never touch the real Application Support folder.
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func rate(_ input: Double) -> ModelPrice {
        ModelPrice(input: input, output: 10, cacheRead: 0.1, cacheWrite5m: 1, cacheWrite1h: 2)
    }

    private func table(version: Int?, models: [String: ModelPrice], discount: Double? = 0,
                       webSearch: Double? = 0.01, usOnly: Double? = 1.1) -> PricingTable {
        PricingTable(models: models, fallback: rate(5), discountPercent: discount, version: version,
                     webSearchCost: webSearch, usOnlyMultiplier: usOnly)
    }

    @discardableResult
    private func writeInstalled(_ table: PricingTable, in dir: URL) throws -> Data {
        let data = try JSONEncoder().encode(table)
        try data.write(to: dir.appendingPathComponent("pricing.json"))
        return data
    }

    private func writeBaseline(_ table: PricingTable, in dir: URL) throws {
        try JSONEncoder().encode(table).write(to: Persistence.baselineURL(in: dir))
    }

    private func bytes(_ name: String, in dir: URL) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func backups(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("pricing.json.backup-") }
    }

    func testSeedWritesBundledTableAndBaselineWhenNoInstalledFile() throws {
        let dir = try makeDirectory()
        let bundled = table(version: 6, models: ["sol": rate(5.5)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded, bundled)
        XCTAssertEqual(Persistence.readBaseline(in: dir), bundled)
        let written = try JSONDecoder().decode(PricingTable.self, from: XCTUnwrap(bytes("pricing.json", in: dir)))
        XCTAssertEqual(written, bundled)
    }

    func testSameVersionEqualTableRecordsBaselineWithoutChangingInstalledBytes() throws {
        let dir = try makeDirectory()
        let bundled = table(version: 6, models: ["sol": rate(5.5)])
        let original = try writeInstalled(bundled, in: dir)

        XCTAssertEqual(Persistence.loadPricing(in: dir, bundled: bundled), bundled)
        XCTAssertEqual(Persistence.readBaseline(in: dir), bundled)
        XCTAssertEqual(bytes("pricing.json", in: dir), original)
        XCTAssertTrue(backups(in: dir).isEmpty)
    }

    func testFailedBackupLeavesInstalledFileAndBaselineUnchanged() throws {
        let dir = try makeDirectory()
        let original = try writeInstalled(table(version: 5, models: ["sol": rate(7)]), in: dir)
        let bundled = table(version: 6, models: ["sol": rate(5.5), "new-model": rate(2)])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)
        XCTAssertEqual(loaded.version, 6, "the merged table is usable in memory")
        XCTAssertEqual(loaded.models["sol"], rate(7))
        XCTAssertEqual(loaded.models["new-model"], rate(2))
        XCTAssertEqual(bytes("pricing.json", in: dir), original)
        XCTAssertNil(Persistence.readBaseline(in: dir))
        XCTAssertTrue(backups(in: dir).isEmpty)
    }

    func testFailedBaselineWriteKeepsSuccessfullyUpgradedPricingAndOriginalBackup() throws {
        let dir = try makeDirectory()
        let original = try writeInstalled(table(version: 5, models: ["sol": rate(7)]), in: dir)
        try FileManager.default.createDirectory(at: Persistence.baselineURL(in: dir), withIntermediateDirectories: false)
        let bundled = table(version: 6, models: ["sol": rate(5.5), "new-model": rate(2)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)
        let written = try JSONDecoder().decode(PricingTable.self, from: XCTUnwrap(bytes("pricing.json", in: dir)))
        XCTAssertEqual(written, loaded)
        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(loaded.models["sol"], rate(7))
        XCTAssertEqual(loaded.models["new-model"], rate(2))
        XCTAssertNil(Persistence.readBaseline(in: dir))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups(in: dir).first)), original)
    }

    func testFirstUpgradeWithoutBaselineKeepsOldRatesAndCustomEntries() throws {
        let dir = try makeDirectory()
        try writeInstalled(table(version: 5, models: ["sol": rate(1), "opus": rate(7), "my-model": rate(9)], discount: 15), in: dir)
        let bundled = table(version: 6, models: ["sol": rate(5.5), "opus": rate(5), "luna": rate(1.1)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(loaded.models["sol"], rate(1))
        XCTAssertEqual(loaded.models["opus"], rate(7))
        XCTAssertEqual(loaded.models["my-model"], rate(9))
        XCTAssertEqual(loaded.models["luna"], rate(1.1))
        XCTAssertEqual(loaded.discountPercent, 15)
        XCTAssertEqual(Persistence.readBaseline(in: dir), bundled)
    }

    func testFirstUpgradeAddsNewModelWithBundledHistoryAndPricesAfterTheDate() throws {
        let dir = try makeDirectory()
        try writeInstalled(table(version: 5, models: ["sol": rate(5.5)]), in: dir)
        var bundled = table(version: 6, models: ["sol": rate(5.5), "luna": rate(1.1)])
        let solRevision = DatedModelPrice(effectiveFrom: "2026-11-01", price: rate(6))
        let lunaRevision = DatedModelPrice(effectiveFrom: "2026-11-01", price: rate(1.5))
        bundled.modelPriceHistory = ["sol": [solRevision], "luna": [lunaRevision]]

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)
        let roundTrip = try JSONDecoder().decode(PricingTable.self, from: JSONEncoder().encode(loaded))

        XCTAssertEqual(loaded.modelPriceHistory?["luna"], [lunaRevision], "a new model takes its bundled history")
        XCTAssertNil(loaded.modelPriceHistory?["sol"], "an existing model with no baseline keeps its installed history")
        XCTAssertEqual(roundTrip, loaded)
        XCTAssertEqual(roundTrip.price(forFamily: "luna", rawModel: "luna", rateDayUTC: "2026-10-31"), rate(1.1))
        XCTAssertEqual(roundTrip.price(forFamily: "luna", rawModel: "luna", rateDayUTC: "2026-11-15"), rate(1.5))
    }

    func testHistoryKeysMergePerModelAndKeepUserRevisions() throws {
        let dir = try makeDirectory()
        let oldRevision = DatedModelPrice(effectiveFrom: "2026-01-01", price: rate(1))
        let userRevision = DatedModelPrice(effectiveFrom: "2026-06-01", price: rate(7))
        var previous = table(version: 5, models: ["sol": rate(1), "opus": rate(5)])
        previous.modelPriceHistory = ["sol": [oldRevision], "opus": [oldRevision]]
        try writeBaseline(previous, in: dir)
        var installed = table(version: 5, models: ["sol": rate(1), "opus": rate(5)])
        installed.modelPriceHistory = ["sol": [oldRevision, userRevision], "opus": [oldRevision]]
        try writeInstalled(installed, in: dir)
        var bundled = table(version: 6, models: ["sol": rate(5.5), "opus": rate(5)])
        let newRevision = DatedModelPrice(effectiveFrom: "2026-11-01", price: rate(5.5))
        bundled.modelPriceHistory = ["sol": [oldRevision, newRevision], "opus": [oldRevision, newRevision]]

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.modelPriceHistory?["sol"], [oldRevision, userRevision], "user-edited key is kept")
        XCTAssertEqual(loaded.modelPriceHistory?["opus"], [oldRevision, newRevision], "unmodified key follows the bundled history")
    }

    func testBackupHoldsExactOriginalBytesBeforeUpgrade() throws {
        let dir = try makeDirectory()
        let original = Data(#"{"version":5,"models":{"sol":{"input":1,"output":10,"cacheRead":0.1,"cacheWrite5m":1,"#.utf8)
            + Data(#""cacheWrite1h":2}},"fallback":{"input":5,"output":25,"cacheRead":0.5,"cacheWrite5m":6.25,"#.utf8)
            + Data(#""cacheWrite1h":10}}"#.utf8)
        try original.write(to: dir.appendingPathComponent("pricing.json"))

        _ = Persistence.loadPricing(in: dir, bundled: table(version: 6, models: ["sol": rate(5.5)]))

        let found = backups(in: dir)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(found.first)), original)
    }

    func testCorruptedInstalledFileIsNotReplacedOrBackedUp() throws {
        let dir = try makeDirectory()
        let corrupt = Data("{not json".utf8)
        try corrupt.write(to: dir.appendingPathComponent("pricing.json"))
        let bundled = table(version: 6, models: ["sol": rate(5.5)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded, bundled, "the bundled table is used in memory")
        XCTAssertEqual(bytes("pricing.json", in: dir), corrupt, "the malformed file is left byte-identical")
        XCTAssertTrue(backups(in: dir).isEmpty)
        XCTAssertNil(Persistence.readBaseline(in: dir), "an invalid installed file does not advance the baseline")
    }

    func testCorruptedBaselineIsTreatedAsUnknownAndKeepsInstalledRates() throws {
        let dir = try makeDirectory()
        try writeInstalled(table(version: 5, models: ["sol": rate(1)]), in: dir)
        try Data("garbage".utf8).write(to: Persistence.baselineURL(in: dir))
        let bundled = table(version: 6, models: ["sol": rate(5.5), "luna": rate(1.1)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.models["sol"], rate(1), "unknown baseline: installed rate is kept")
        XCTAssertEqual(loaded.models["luna"], rate(1.1))
    }

    func testDowngradePreservesInstalledTableAndBaseline() throws {
        let dir = try makeDirectory()
        let installed = table(version: 7, models: ["sol": rate(3), "custom": rate(9)], discount: 10)
        let installedBytes = try writeInstalled(installed, in: dir)
        let previousBaseline = table(version: 5, models: ["sol": rate(1)])
        try writeBaseline(previousBaseline, in: dir)

        let loaded = Persistence.loadPricing(in: dir, bundled: table(version: 6, models: ["sol": rate(5.5)]))

        XCTAssertEqual(loaded, installed)
        XCTAssertEqual(bytes("pricing.json", in: dir), installedBytes)
        XCTAssertEqual(Persistence.readBaseline(in: dir), previousBaseline, "the baseline never moves backwards")
        XCTAssertTrue(backups(in: dir).isEmpty)
    }

    func testUpgradeNeverMovesBaselineBackwards() throws {
        let dir = try makeDirectory()
        try writeInstalled(table(version: 5, models: ["sol": rate(1)]), in: dir)
        let newerBaseline = table(version: 7, models: ["sol": rate(3)])
        try writeBaseline(newerBaseline, in: dir)

        _ = Persistence.loadPricing(in: dir, bundled: table(version: 6, models: ["sol": rate(5.5)]))

        XCTAssertEqual(Persistence.readBaseline(in: dir), newerBaseline, "a v7 baseline is not replaced by v6")
    }

    func testDeletedBaseModelDoesNotBreakHistoryRoundTrip() throws {
        let dir = try makeDirectory()
        let oldRevision = DatedModelPrice(effectiveFrom: "2026-01-01", price: rate(1))
        var previous = table(version: 5, models: ["sol": rate(1), "terra": rate(3)])
        previous.modelPriceHistory = ["terra": [oldRevision]]
        try writeBaseline(previous, in: dir)
        var installed = table(version: 5, models: ["sol": rate(1)])
        installed.modelPriceHistory = nil
        try writeInstalled(installed, in: dir)
        var bundled = table(version: 6, models: ["sol": rate(5.5), "terra": rate(3)])
        let newRevision = DatedModelPrice(effectiveFrom: "2026-11-01", price: rate(4))
        bundled.modelPriceHistory = ["terra": [oldRevision, newRevision]]

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)
        let roundTrip = try JSONDecoder().decode(PricingTable.self, from: JSONEncoder().encode(loaded))

        XCTAssertNil(loaded.models["terra"], "the user-deleted model is not restored")
        XCTAssertNil(loaded.modelPriceHistory?["terra"], "orphan history is skipped")
        XCTAssertEqual(roundTrip, loaded)
    }

    func testBundledHistoryDoesNotOverrideUserCustomBaseRate() throws {
        let dir = try makeDirectory()
        try writeBaseline(table(version: 5, models: ["sol": rate(1)]), in: dir)
        try writeInstalled(table(version: 5, models: ["sol": rate(7)]), in: dir)
        var bundled = table(version: 6, models: ["sol": rate(5.5)])
        let newRevision = DatedModelPrice(effectiveFrom: "2026-11-01", price: rate(5.5))
        bundled.modelPriceHistory = ["sol": [newRevision]]

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.models["sol"], rate(7), "user base rate is kept")
        XCTAssertNil(loaded.modelPriceHistory?["sol"], "bundled dated revision is not applied over the user rate")
        let costAfterDate = loaded.price(forFamily: "sol", rawModel: "sol", rateDayUTC: "2026-11-15")
        XCTAssertEqual(costAfterDate, rate(7), "a dated request after the bundled date still uses the user rate")
    }

    func testSameVersionWithoutBaselineDoesNotRecordDifferentRatesAsDefaults() throws {
        let dir = try makeDirectory()
        try writeInstalled(table(version: 6, models: ["sol": rate(2)]), in: dir)

        _ = Persistence.loadPricing(in: dir, bundled: table(version: 6, models: ["sol": rate(5.5)]))

        XCTAssertNil(Persistence.readBaseline(in: dir))
    }

    func testLaterUpgradeRefreshesUnmodifiedDefaultsAndKeepsUserEdits() throws {
        let dir = try makeDirectory()
        try writeBaseline(table(version: 5, models: ["sol": rate(5), "opus": rate(5), "haiku": rate(1), "terra": rate(3)], discount: 0), in: dir)
        try writeInstalled(table(version: 5, models: ["sol": rate(5), "opus": rate(7), "haiku": rate(1), "custom": rate(9)], discount: 15), in: dir)
        let bundled = table(version: 6, models: ["sol": rate(5.5), "opus": rate(5), "haiku": rate(2), "terra": rate(3), "luna": rate(1.1)])

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.models["sol"], rate(5.5), "unmodified default follows the bundled rate")
        XCTAssertEqual(loaded.models["haiku"], rate(2), "unmodified default follows the bundled rate")
        XCTAssertEqual(loaded.models["opus"], rate(7), "user edit is kept")
        XCTAssertEqual(loaded.models["custom"], rate(9), "user-only entry is kept")
        XCTAssertNil(loaded.models["terra"], "a key the user deleted is not added again")
        XCTAssertEqual(loaded.models["luna"], rate(1.1), "a new bundled key is added")
        XCTAssertEqual(loaded.discountPercent, 15)
        XCTAssertEqual(loaded.version, 6)
        XCTAssertEqual(Persistence.readBaseline(in: dir), bundled)
    }

    func testUserEditedFallbackAndMultipliersAreKeptWhileUnchangedOnesRefresh() throws {
        let dir = try makeDirectory()
        // Baseline has fallback rate(5), webSearchCost 0.01 and usOnlyMultiplier 1.1.
        // The installed file edited fallback (rate 8) and usOnlyMultiplier (2.0); webSearchCost is unedited.
        try writeBaseline(table(version: 5, models: [:], webSearch: 0.01, usOnly: 1.1), in: dir)
        var installed = table(version: 5, models: [:], webSearch: 0.01, usOnly: 2.0)
        installed.fallback = rate(8)
        try writeInstalled(installed, in: dir)
        var bundled = table(version: 6, models: [:], webSearch: 0.02, usOnly: 1.2)
        bundled.fallback = rate(6)

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.fallback, rate(8), "user-edited fallback is kept")
        XCTAssertEqual(loaded.usOnlyMultiplier, 2.0, "user-edited usOnlyMultiplier is kept")
        XCTAssertEqual(loaded.webSearchCost, 0.02, "unmodified webSearchCost follows the bundled value")
    }

    func testUnmodifiedFallbackRefreshesToBundledValue() throws {
        let dir = try makeDirectory()
        var baseline = table(version: 5, models: [:], webSearch: 0.01, usOnly: 1.1)
        baseline.fallback = rate(5)
        try writeBaseline(baseline, in: dir)
        try writeInstalled(baseline, in: dir)
        var bundled = table(version: 6, models: [:], webSearch: 0.01, usOnly: 1.1)
        bundled.fallback = rate(6)

        let loaded = Persistence.loadPricing(in: dir, bundled: bundled)

        XCTAssertEqual(loaded.fallback, rate(6), "unmodified fallback follows the bundled value")
    }

    func testSnapshotWithoutLastCostedPricingDecodesToNil() throws {
        let legacy = Data(#"{"aggregates":{},"dataVersion":5,"pricingVersion":5}"#.utf8)

        let decoded = try JSONDecoder().decode(Persistence.Snapshot.self, from: legacy)

        XCTAssertNil(decoded.lastCostedPricing)
        XCTAssertEqual(decoded.pricingVersion, 5)
    }

    func testNeedsRecostWhenCostedTableIsUnknownOrDiffers() {
        let costed = table(version: 6, models: ["sol": rate(5.5)])
        var snapshot = Persistence.Snapshot()
        snapshot.pricingVersion = 6
        snapshot.lastCostedPricing = costed

        XCTAssertFalse(snapshot.needsRecost(pricing: costed), "known and equal: no recost")
        XCTAssertTrue(snapshot.needsRecost(pricing: table(version: 6, models: ["sol": rate(2)])),
                      "same version, different content")

        snapshot.lastCostedPricing = nil
        XCTAssertTrue(snapshot.needsRecost(pricing: costed), "unknown provenance: recost even at the same version")
        XCTAssertTrue(snapshot.needsRecost(pricing: table(version: 6, models: ["sol": rate(2)])))
    }

    func testNeedsRecostTriggersOnDifferentContentAtLowerVersion() {
        var snapshot = Persistence.Snapshot()
        snapshot.pricingVersion = 6
        snapshot.lastCostedPricing = table(version: 6, models: ["sol": rate(5.5)])

        XCTAssertTrue(snapshot.needsRecost(pricing: table(version: 5, models: ["sol": rate(1)])),
                      "content differs even though the version went down")
    }

    func testSeedIgnoresUndecodableBundledBytesAndEncodesTheTableInUse() throws {
        let dir = try makeDirectory()
        let bundled = table(version: 6, models: ["sol": rate(5.5)])

        let loaded = Persistence.seedPricing(bundled: bundled, bundledBytes: Data("garbage".utf8), in: dir)

        XCTAssertEqual(loaded, bundled)
        let written = try JSONDecoder().decode(PricingTable.self, from: XCTUnwrap(bytes("pricing.json", in: dir)))
        XCTAssertEqual(written, bundled)
        XCTAssertEqual(Persistence.readBaseline(in: dir), bundled)
    }

    func testNeedsRecostTriggersOnHigherVersion() {
        var snapshot = Persistence.Snapshot()
        snapshot.pricingVersion = 5
        snapshot.lastCostedPricing = table(version: 5, models: ["sol": rate(1)])

        XCTAssertTrue(snapshot.needsRecost(pricing: table(version: 6, models: ["sol": rate(1)])))
    }

    func testMigrationToV6ClearsOnlyAccountingState() {
        var snapshot = Persistence.Snapshot()
        snapshot.dataVersion = 5
        snapshot.aggregates = ["2026-11-01": DailyAggregate(day: "2026-11-01")]
        snapshot.launchAtLogin = true
        snapshot.lastTipDay = ["tip": "2026-11-01"]

        let result = Persistence.migrate(snapshot)

        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.snapshot.dataVersion, 6)
        XCTAssertTrue(result.snapshot.aggregates.isEmpty)
        XCTAssertTrue(result.snapshot.launchAtLogin)
        XCTAssertEqual(result.snapshot.lastTipDay, ["tip": "2026-11-01"])
    }
}
