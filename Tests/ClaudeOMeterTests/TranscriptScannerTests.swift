import XCTest
@testable import ClaudeOMeter

final class TranscriptScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so pathComponent arithmetic matches enumerator URLs.
        tempDir = base.resolvingSymlinksInPath()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeLines(_ lines: [String], to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        try! data.write(to: url)
    }

    /// Builds a valid JSONL usage line with the given timestamp (ISO-8601).
    private func usageLine(timestamp: String) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"msg-\(timestamp)\",\"usage\":{\"input_tokens\":100}}}"
    }

    /// Returns today's date in "YYYY-MM-DD" format (as expected by scanConcurrency).
    private var todayDay: String { DayBucket.localDay(from: Date()) }

    /// Returns "YYYY-MM-DDT" prefix for today, ready to append "HH:MM:SS.000Z".
    private var todayPrefix: String { todayDay + "T" }

    // MARK: - Empty directory

    func testEmptyDirectoryReturnsZeroConcurrency() {
        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 0)
        XCTAssertEqual(stats.peakSubagents, 0)
        XCTAssertTrue(stats.peakProjectNames.isEmpty)
    }

    // MARK: - Concurrent user sessions

    func testTwoSessionsInSameWindowCountAsPeakTwo() {
        // Both sessions have usage events at 14:00 → same 5-minute bucket → peak = 2
        let ts1 = todayPrefix + "14:00:00.000Z"
        let ts2 = todayPrefix + "14:02:00.000Z"
        let proj = tempDir.appendingPathComponent("proj-alpha", isDirectory: true)
        writeLines([usageLine(timestamp: ts1)], to: proj.appendingPathComponent("session-a.jsonl"))
        writeLines([usageLine(timestamp: ts2)], to: proj.appendingPathComponent("session-b.jsonl"))

        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 2)
    }

    func testNonOverlappingSessionsCountAsPeakOne() {
        // Session A at 14:00, session B at 14:30 → different 5-minute buckets → peak = 1
        let ts1 = todayPrefix + "14:00:00.000Z"
        let ts2 = todayPrefix + "14:30:00.000Z"
        let proj = tempDir.appendingPathComponent("proj-beta", isDirectory: true)
        writeLines([usageLine(timestamp: ts1)], to: proj.appendingPathComponent("session-a.jsonl"))
        writeLines([usageLine(timestamp: ts2)], to: proj.appendingPathComponent("session-b.jsonl"))

        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 1)
    }

    // MARK: - Subagents counted separately

    func testSubagentsCountedSeparatelyFromUserSessions() {
        let ts = todayPrefix + "14:00:00.000Z"
        let proj = tempDir.appendingPathComponent("proj-gamma", isDirectory: true)
        // One user session
        writeLines([usageLine(timestamp: ts)], to: proj.appendingPathComponent("session-u.jsonl"))
        // One subagent session
        let subagentDir = proj.appendingPathComponent("subagents", isDirectory: true)
        writeLines([usageLine(timestamp: ts)], to: subagentDir.appendingPathComponent("session-s.jsonl"))

        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 1, "User session should count once")
        XCTAssertEqual(stats.peakSubagents, 1, "Subagent session should count separately")
    }

    // MARK: - Other-day lines ignored

    func testYesterdayLinesAreNotCounted() {
        let yesterday = DayBucket.day(daysAgo: 1)
        let ts = yesterday + "T14:00:00.000Z"
        let proj = tempDir.appendingPathComponent("proj-delta", isDirectory: true)
        writeLines([usageLine(timestamp: ts)], to: proj.appendingPathComponent("old-session.jsonl"))

        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 0, "Lines from a previous day must not be counted")
    }

    // MARK: - Malformed timestamp (C1 regression)

    func testMalformedTimestampDoesNotCrash() {
        // A timestamp shorter than 16 characters must be ignored without crashing.
        let badLine = "{\"timestamp\":\"2026-07\",\"message\":{\"id\":\"msg-short\",\"usage\":{\"input_tokens\":1}}}"
        let normalLine = usageLine(timestamp: todayPrefix + "14:00:00.000Z")
        let proj = tempDir.appendingPathComponent("proj-epsilon", isDirectory: true)
        writeLines([badLine, normalLine], to: proj.appendingPathComponent("session-crash.jsonl"))

        // Must not crash; the malformed line is silently skipped, the valid one is counted.
        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 1, "Valid line should still be counted after malformed one")
    }

    // MARK: - Peak project names

    func testPeakProjectNamesAreCapturedForConcurrentSessions() {
        let ts = todayPrefix + "14:00:00.000Z"
        // Two projects, each with one session at the same time → concurrent
        let projA = tempDir.appendingPathComponent("-Users-me-git-alpha", isDirectory: true)
        let projB = tempDir.appendingPathComponent("-Users-me-git-beta", isDirectory: true)
        writeLines([usageLine(timestamp: ts)], to: projA.appendingPathComponent("s1.jsonl"))
        writeLines([usageLine(timestamp: ts)], to: projB.appendingPathComponent("s2.jsonl"))

        let stats = TranscriptScanner.scanConcurrency(for: todayDay, rootDirectory: tempDir)
        XCTAssertEqual(stats.peakUserSessions, 2)
        XCTAssertFalse(stats.peakProjectNames.isEmpty, "At least one project name should be captured")
    }

    // MARK: - Hourly slices

    /// A usage line with an explicit model and cache-read tokens, at a given timestamp.
    private func modelUsageLine(id: String, timestamp: String, model: String, cacheRead: Int) -> String {
        "{\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{\"cache_read_input_tokens\":\(cacheRead)}}}"
    }

    func testScanHourlyBucketsByLocalHour() {
        // Two events in local hour 9, one in local hour 14.
        let proj = tempDir.appendingPathComponent("proj-hourly", isDirectory: true)
        writeLines([
            modelUsageLine(id: "m1", timestamp: isoForLocalHour(9, minute: 5), model: "claude-sonnet-4-6", cacheRead: 1_000_000),
            modelUsageLine(id: "m2", timestamp: isoForLocalHour(9, minute: 40), model: "claude-sonnet-4-6", cacheRead: 1_000_000),
            modelUsageLine(id: "m3", timestamp: isoForLocalHour(14, minute: 0), model: "claude-sonnet-4-6", cacheRead: 1_000_000),
        ], to: proj.appendingPathComponent("session.jsonl"))

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertEqual(slices.count, 24, "Always returns a full 24-hour array")
        XCTAssertTrue(slices[9].cost > 0, "Hour 9 should have spend")
        XCTAssertTrue(slices[14].cost > 0, "Hour 14 should have spend")
        // Hour 9 had two identical events → roughly double hour 14's single event.
        XCTAssertEqual(slices[9].cost, slices[14].cost * 2, accuracy: slices[14].cost * 0.01)
        XCTAssertEqual(slices[0].cost, 0, "Idle hour has zero spend")
    }

    func testScanHourlyDedupsByMessageID() {
        // The same message.id appears in two files (session resume / compaction) → counted once.
        let projA = tempDir.appendingPathComponent("proj-a", isDirectory: true)
        let projB = tempDir.appendingPathComponent("proj-b", isDirectory: true)
        let dup = modelUsageLine(id: "same-id", timestamp: isoForLocalHour(10, minute: 0), model: "claude-sonnet-4-6", cacheRead: 1_000_000)
        writeLines([dup], to: projA.appendingPathComponent("s1.jsonl"))
        writeLines([dup], to: projB.appendingPathComponent("s2.jsonl"))

        // A single copy for comparison, in an isolated root.
        let solo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        writeLines([dup], to: solo.appendingPathComponent("proj/s.jsonl"))
        defer { try? FileManager.default.removeItem(at: solo) }

        let deduped = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)[10].cost
        let single = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: solo.resolvingSymlinksInPath(), pricing: .default)[10].cost
        XCTAssertEqual(deduped, single, accuracy: 0.0001, "Duplicate message.id must not double-count")
        XCTAssertTrue(deduped > 0, "Sanity: the event has cost")
    }

    func testScanHourlyIgnoresOtherDays() {
        let proj = tempDir.appendingPathComponent("proj-days", isDirectory: true)
        writeLines([
            modelUsageLine(id: "old", timestamp: isoForLocalHour(9, minute: 0, daysAgo: 1), model: "claude-sonnet-4-6", cacheRead: 1_000_000),
        ], to: proj.appendingPathComponent("s.jsonl"))

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.cost }, 0, "A different day's spend must not appear")
    }

    func testScanHourlySyntheticIsFree() {
        let proj = tempDir.appendingPathComponent("proj-synthetic", isDirectory: true)
        writeLines([
            modelUsageLine(id: "syn", timestamp: isoForLocalHour(11, minute: 0), model: "<synthetic>", cacheRead: 5_000_000),
        ], to: proj.appendingPathComponent("s.jsonl"))

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertEqual(slices[11].cost, 0, "Synthetic messages cost $0 and are dropped")
    }

    func testScanHourlySkipsMalformedLineButKeepsValid() {
        // A corrupt line (e.g. a partial write on crash) must not lose adjacent valid entries.
        let proj = tempDir.appendingPathComponent("proj-malformed", isDirectory: true)
        let bad = "{ this is not valid json"
        let good = modelUsageLine(id: "ok", timestamp: isoForLocalHour(13, minute: 0), model: "claude-sonnet-4-6", cacheRead: 1_000_000)
        writeLines([bad, good], to: proj.appendingPathComponent("s.jsonl"))

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertTrue(slices[13].cost > 0, "Valid line is still counted after a malformed one")
    }

    func testScanHourlyAccumulatesMultipleModelsInSameHour() {
        // Two different families in the same hour must both land in perModel, not overwrite.
        let proj = tempDir.appendingPathComponent("proj-multimodel", isDirectory: true)
        writeLines([
            modelUsageLine(id: "h", timestamp: isoForLocalHour(15, minute: 5), model: "claude-haiku-4-5", cacheRead: 1_000_000),
            modelUsageLine(id: "o", timestamp: isoForLocalHour(15, minute: 40), model: "claude-opus-4-8", cacheRead: 1_000_000),
        ], to: proj.appendingPathComponent("s.jsonl"))

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertNotNil(slices[15].perModel["haiku"], "Haiku bucketed into perModel")
        XCTAssertNotNil(slices[15].perModel["opus"], "Opus bucketed into perModel")
        XCTAssertTrue((slices[15].perModel["haiku"] ?? 0) > 0)
        XCTAssertTrue((slices[15].perModel["opus"] ?? 0) > 0)
        // The hour's total equals the sum of its per-model parts.
        let partSum = slices[15].perModel.values.reduce(0, +)
        XCTAssertEqual(slices[15].cost, partSum, accuracy: 1e-9)
    }

    func testScanHourlyModDateFastPathSkipsBackdatedFile() {
        // A file back-dated before the target day is skipped by the mod-date fast-path even
        // though its content is stamped for today — proving the optimization is exercised.
        let proj = tempDir.appendingPathComponent("proj-backdated", isDirectory: true)
        let url = proj.appendingPathComponent("s.jsonl")
        writeLines([
            modelUsageLine(id: "bd", timestamp: isoForLocalHour(16, minute: 0), model: "claude-sonnet-4-6", cacheRead: 1_000_000),
        ], to: url)
        // Back-date the file's modification time to 3 days ago (before today's dayStart).
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        try! FileManager.default.setAttributes([.modificationDate: threeDaysAgo], ofItemAtPath: url.path)

        let slices = TranscriptScanner.scanHourly(for: todayDay, rootDirectory: tempDir, pricing: .default)
        XCTAssertEqual(slices[16].cost, 0, "Back-dated file is skipped by the mod-date fast-path")
    }

    /// Full ISO-8601 (UTC, fractional seconds) timestamp for a given *local* wall-clock hour on
    /// today (or `daysAgo` days before). Converting through UTC ensures scanHourly's local-hour
    /// bucketing lands on the intended hour regardless of the test machine's timezone.
    private func isoForLocalHour(_ hour: Int, minute: Int, daysAgo: Int = 0) -> String {
        let base = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        // Fall back to noon UTC if the requested local time doesn't exist (DST spring-forward
        // gap) — avoids a force-unwrap crash on the one transition hour per year.
        let date = Calendar.current.date(from: comps)
            ?? Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: base)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }
}
