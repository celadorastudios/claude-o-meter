import Foundation
import XCTest
@testable import ClaudeOMeter

final class SolTranscriptTests: XCTestCase {
    private let rawModel = "bedrock_mantle/openai.gpt-6.1-sol"
    private let expectedCost = 0.20819766

    func testUnsplitCacheCreationWithZeroBreakdownKeepsDisjointTokenBuckets() throws {
        let line = try transcriptLine(id: "message-1", write: 27_302, read: 30_823, output: 20)
        let record = try XCTUnwrap(TranscriptScanner.parseCandidate(line))
        XCTAssertEqual(record.rawModel, rawModel)
        XCTAssertEqual(record.model, "sol")
        XCTAssertEqual(record.usage.input, 2)
        XCTAssertEqual(record.usage.output, 20)
        XCTAssertEqual(record.usage.cacheRead, 30_823)
        XCTAssertEqual(record.usage.cacheWrite5m, 27_302)
        XCTAssertEqual(record.usage.cacheWrite1h, 0)
    }

    func testScanDeduplicatesSolTranscriptAndFoldsCorrectModelAndProjectCosts() throws {
        let root = try makeTranscriptRoot()
        let scanner = TranscriptScanner(rootDirectory: root)
        let first = scanner.scan(state: ScanState())
        XCTAssertEqual(first.records.count, 11)
        XCTAssertEqual(first.state.seenIDs.count, 11)
        XCTAssertTrue(first.records.allSatisfy { $0.projectDir == "test-project" })

        var aggregates: [String: DailyAggregate] = [:]
        Aggregator.fold(records: first.records, into: &aggregates, pricing: .default)
        try assertCorrectSolAggregate(aggregates)

        let second = scanner.scan(state: first.state)
        XCTAssertTrue(second.records.isEmpty)
        Aggregator.fold(records: second.records, into: &aggregates, pricing: .default)
        try assertCorrectSolAggregate(aggregates)

        // A copied transcript must also remain deduplicated when its bytes are new to the scanner.
        let project = root.appendingPathComponent("test-project")
        try FileManager.default.copyItem(at: project.appendingPathComponent("session.jsonl"),
                                         to: project.appendingPathComponent("resumed.jsonl"))
        let copied = scanner.scan(state: second.state)
        XCTAssertTrue(copied.records.isEmpty)
        Aggregator.fold(records: copied.records, into: &aggregates, pricing: .default)
        try assertCorrectSolAggregate(aggregates)
    }

    func testVersion4MigrationRebuildsSolModelAndProjectCostsAndPreservesPreferences() throws {
        let root = try makeTranscriptRoot()
        let scanner = TranscriptScanner(rootDirectory: root)
        let original = scanner.scan(state: ScanState())
        var snapshot = Persistence.Snapshot()
        snapshot.dataVersion = 4
        snapshot.scanState = original.state
        snapshot.settings = AlertSettings(dailyThreshold: 25, monthlyThreshold: 300)
        snapshot.settings.tipsEnabled = false
        snapshot.lastAlertDay = ["daily": original.records[0].day]
        snapshot.lastTipDay = ["cache_hit": original.records[0].day]

        var oldPricing = PricingTable.default
        oldPricing.models[rawModel] = ModelPrice(input: 5.5, output: 33, cacheRead: 0,
                                                cacheWrite5m: 0, cacheWrite1h: 0)
        Aggregator.fold(records: original.records, into: &snapshot.aggregates, pricing: oldPricing)
        XCTAssertEqual(snapshot.aggregates.values.first?.totalCost ?? -1, 0.09955, accuracy: 1e-9)
        XCTAssertFalse(snapshot.scanState.cursors.isEmpty)
        XCTAssertFalse(snapshot.scanState.seenIDs.isEmpty)

        let migration = Persistence.migrate(snapshot)
        XCTAssertTrue(migration.didMigrate)
        var rebuilt = migration.snapshot
        XCTAssertEqual(rebuilt.dataVersion, 6)
        XCTAssertTrue(rebuilt.scanState.cursors.isEmpty)
        XCTAssertTrue(rebuilt.scanState.seenIDs.isEmpty)
        XCTAssertTrue(rebuilt.aggregates.isEmpty)
        XCTAssertEqual(rebuilt.settings.dailyThreshold, 25)
        XCTAssertEqual(rebuilt.settings.monthlyThreshold, 300)
        XCTAssertFalse(rebuilt.settings.tipsEnabled)
        XCTAssertEqual(rebuilt.lastAlertDay, snapshot.lastAlertDay)
        XCTAssertEqual(rebuilt.lastTipDay, snapshot.lastTipDay)
        XCTAssertEqual(snapshot.dataVersion, 4, "Migration must not mutate its input")

        let rescanned = scanner.scan(state: rebuilt.scanState)
        XCTAssertEqual(rescanned.records.count, 11)
        Aggregator.fold(records: rescanned.records, into: &rebuilt.aggregates, pricing: .default)
        try assertCorrectSolAggregate(rebuilt.aggregates)
    }

    /// Sanitized usage counters preserve repeated responses without retaining transcript content.
    private func makeTranscriptRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sol-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let records: [(id: Int, write: Int, read: Int, output: Int)] = [
            (1, 27_302, 0, 20),
            (2, 3_521, 27_302, 19),
            (3, 2_663, 30_823, 144),
            (4, 914, 33_486, 75),
            (4, 914, 33_486, 75),
            (5, 9_237, 34_400, 450),
            (6, 551, 43_637, 411),
            (7, 512, 44_188, 73),
            (8, 174, 44_700, 558),
            (8, 174, 44_700, 558),
            (9, 635, 44_874, 1_029),
            (9, 635, 44_874, 1_029),
            (10, 1_063, 45_509, 45),
            (11, 1_247, 46_572, 189),
        ]
        var data = Data()
        for record in records {
            data.append(try transcriptLine(id: "message-\(record.id)", write: record.write,
                                           read: record.read, output: record.output))
            data.append(0x0A)
        }
        try data.write(to: project.appendingPathComponent("session.jsonl"))
        return root
    }

    private func transcriptLine(id: String, write: Int, read: Int, output: Int) throws -> Data {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let timestamp = ISO8601DateFormatter().string(from: noon)
        let record: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": [
                "id": id,
                "model": rawModel,
                "usage": [
                    "input_tokens": 2,
                    "output_tokens": output,
                    "cache_creation_input_tokens": write,
                    "cache_read_input_tokens": read,
                    "cache_creation": ["ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: record)
    }

    private func assertCorrectSolAggregate(_ aggregates: [String: DailyAggregate],
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(aggregates.count, 1, file: file, line: line)
        let day = try XCTUnwrap(aggregates.values.first, file: file, line: line)
        let model = try XCTUnwrap(day.perModel["sol"], file: file, line: line)
        XCTAssertEqual(model.usage.input, 22, file: file, line: line)
        XCTAssertEqual(model.usage.output, 3_013, file: file, line: line)
        XCTAssertEqual(model.usage.cacheWrite5m, 47_819, file: file, line: line)
        XCTAssertEqual(model.usage.cacheWrite1h, 0, file: file, line: line)
        XCTAssertEqual(model.usage.cacheRead, 395_491, file: file, line: line)
        XCTAssertEqual(model.cost, expectedCost, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(day.totalCost, expectedCost, accuracy: 1e-9, file: file, line: line)
        let project = try XCTUnwrap(day.perProject["test-project"], file: file, line: line)
        XCTAssertEqual(project.cost, expectedCost, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(project.perModel["sol"] ?? -1, expectedCost, accuracy: 1e-9, file: file, line: line)
    }
}
