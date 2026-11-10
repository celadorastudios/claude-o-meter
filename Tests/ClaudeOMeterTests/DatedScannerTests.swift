import XCTest
@testable import ClaudeOMeter

final class DatedScannerTests: XCTestCase {
    func testCandidateKeepsUTCPriceDayAndLocalDisplayDayAndHour() throws {
        let cases = [
            ("2026-11-01T23:30:00.125Z", "2026-11-01T23:30:00Z", "2026-11-01"),
            ("2026-11-02T00:30:00Z", "2026-11-02T00:30:00Z", "2026-11-02"),
            ("2026-11-02T00:30:00.125+02:00", "2026-11-01T22:30:00Z", "2026-11-01"),
            ("2026-11-01T23:30:00-02:00", "2026-11-02T01:30:00Z", "2026-11-02"),
        ]
        let formatter = ISO8601DateFormatter()
        for (timestamp, utcTimestamp, utcDay) in cases {
            let instant = try XCTUnwrap(formatter.date(from: utcTimestamp))
            let record = try XCTUnwrap(TranscriptScanner.parseCandidate(
                Data(try line(id: timestamp, timestamp: timestamp).utf8)))
            XCTAssertEqual(DayBucket.utcDay(from: instant), utcDay)
            XCTAssertEqual(record.rateDayUTC, utcDay, timestamp)
            XCTAssertEqual(record.day, localDay(instant), timestamp)
            XCTAssertEqual(record.hour, Calendar.current.component(.hour, from: instant), timestamp)
        }
    }

    func testCandidateRejectsAnInvalidTimestamp() throws {
        XCTAssertNil(TranscriptScanner.parseCandidate(Data(try line(id: "bad", timestamp: "not-a-date").utf8)))
    }

    func testIncrementalScanPreservesUTCDateWhileAddingProjectAndDeduplicating() throws {
        let timestamp = "2026-11-02T00:30:00+02:00"
        let first = try line(id: "same", timestamp: timestamp, usage: ["input_tokens": 10])
        let final = try line(id: "same", timestamp: timestamp, usage: ["input_tokens": 20, "speed": "fast"])
        try withTranscript([first, final]) { root, file in
            let scanner = TranscriptScanner(rootDirectory: root)
            let initial = scanner.scan(state: ScanState())
            XCTAssertEqual(initial.records.count, 1)
            let record = try XCTUnwrap(initial.records.first)
            XCTAssertEqual(record.projectDir, "proj-dated")
            XCTAssertEqual(record.rateDayUTC, "2026-11-01")
            XCTAssertEqual(record.usage.input, 20)
            XCTAssertTrue(record.isFast)
            XCTAssertEqual(initial.state.seenIDs["same"], record.day)
            XCTAssertEqual(initial.state.cursors.count, 1)
            XCTAssertEqual(initial.state.cursors.values.first, UInt64(try Data(contentsOf: file).count))
            XCTAssertTrue(scanner.scan(state: initial.state).records.isEmpty)

            let next = try line(id: "new", timestamp: "2026-11-01T23:30:00-02:00")
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((final + "\n" + next + "\n").utf8))
            let incremental = scanner.scan(state: initial.state)
            XCTAssertEqual(incremental.records.count, 1)
            let newRecord = try XCTUnwrap(incremental.records.first)
            XCTAssertEqual(newRecord.id, "new")
            XCTAssertEqual(newRecord.projectDir, "proj-dated")
            XCTAssertEqual(newRecord.rateDayUTC, "2026-11-02")
            XCTAssertEqual(incremental.state.seenIDs["new"], newRecord.day)
            XCTAssertEqual(incremental.state.seenIDs["same"], record.day)
        }
    }

    func testHourlyUsesTheSameUTCRevisionForBaseAndFastPrices() throws {
        let base = ModelPrice(input: 2, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, fastMultiplier: 2)
        let revised = ModelPrice(input: 5, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, fastMultiplier: 3)
        let pricing = PricingTable(models: ["vendor/sonnet-test": base], usOnlyMultiplier: 1.25,
            modelPriceHistory: ["vendor/sonnet-test": [DatedModelPrice(effectiveFrom: "2026-11-02", price: revised)]])
        let cases = [
            ("2026-11-02T00:30:00.125+02:00", 5.0),
            ("2026-11-01T23:30:00-02:00", 18.75),
        ]
        for (timestamp, expectedCost) in cases {
            let date = try XCTUnwrap(DayBucket.date(fromISO: timestamp))
            let day = localDay(date)
            let hour = Calendar.current.component(.hour, from: date)
            let event = try line(id: "dated", timestamp: timestamp,
                usage: ["input_tokens": 1_000_000, "speed": "fast", "inference_geo": "us"])
            try withTranscript([event]) { root, file in
                // The scanner's file-date fast path must not hide a dated fixture.
                try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(86_400)], ofItemAtPath: file.path)
                let slices = TranscriptScanner.scanHourly(for: day, rootDirectory: root, pricing: pricing)
                XCTAssertEqual(slices.count, 24)
                XCTAssertEqual(slices[hour].cost, expectedCost, accuracy: 1e-9, timestamp)
                XCTAssertEqual(slices[hour].perModel["sonnet"] ?? 0, expectedCost, accuracy: 1e-9)
                XCTAssertEqual(slices.reduce(0) { $0 + $1.cost }, expectedCost, accuracy: 1e-9)
                let otherDay = localDay(try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: date)))
                let otherSlices = TranscriptScanner.scanHourly(for: otherDay, rootDirectory: root, pricing: pricing)
                XCTAssertEqual(otherSlices.reduce(0) { $0 + $1.cost }, 0)
            }
        }
    }

    func testHourlyDatedPriceKeepsCacheBucketsAndWholePromptTier() throws {
        let noon = try localNoon()
        let rateDay = DayBucket.utcDay(from: noon)
        let base = ModelPrice(input: 100, output: 100, cacheRead: 100, cacheWrite5m: 100, cacheWrite1h: 100)
        let revised = ModelPrice(input: 1, output: 2, cacheRead: 3, cacheWrite5m: 4, cacheWrite1h: 5,
            longContextThreshold: 10,
            longContext: LongContextPrice(input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50))
        let pricing = PricingTable(models: ["vendor/sonnet-test": base],
            modelPriceHistory: ["vendor/sonnet-test": [DatedModelPrice(effectiveFrom: rateDay, price: revised)]])
        for input in [1, 2] {
            let event = try line(id: "cache-tier", timestamp: iso(noon), usage: [
                "input_tokens": input, "output_tokens": 2, "cache_read_input_tokens": 3,
                "cache_creation_input_tokens": 6,
                "cache_creation": ["ephemeral_5m_input_tokens": 4, "ephemeral_1h_input_tokens": 2],
            ])
            try withTranscript([event]) { root, _ in
                let slices = TranscriptScanner.scanHourly(for: localDay(noon), rootDirectory: root, pricing: pricing)
                // Prompt lengths 10 and 11 straddle the threshold, including both cache-write buckets.
                let expected = input == 1 ? 40.0 / 1_000_000 : 410.0 / 1_000_000
                XCTAssertEqual(slices[12].cost, expected, accuracy: 1e-12)
                XCTAssertEqual(slices.reduce(0) { $0 + $1.cost }, expected, accuracy: 1e-12)
            }
        }
    }

    private func withTranscript(_ lines: [String], _ body: (URL, URL) throws -> Void) throws {
        let temporaryDirectory = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = temporaryDirectory.appendingPathComponent("dated-scanner-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("proj-dated/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try body(root.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }

    private func line(id: String, timestamp: String, usage: [String: Any] = ["input_tokens": 1_000_000]) throws -> String {
        let object: [String: Any] = [
            "timestamp": timestamp,
            "message": ["id": id, "model": "vendor/sonnet-test", "usage": usage],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func localNoon() throws -> Date {
        try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
