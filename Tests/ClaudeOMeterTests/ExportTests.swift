import XCTest
@testable import ClaudeOMeter

final class ExportTests: XCTestCase {

    private func sampleAggregates() -> [String: DailyAggregate] {
        var day1 = DailyAggregate(day: "2025-07-14")
        day1.perModel["opus"] = ModelUsage(model: "opus", rawModel: "claude-opus-4-8",
                                           usage: TokenUsage(input: 1000, output: 500, cacheRead: 200, cacheWrite5m: 100, cacheWrite1h: 50),
                                           cost: 0.05)
        day1.perModel["sonnet"] = ModelUsage(model: "sonnet", rawModel: "claude-sonnet-5",
                                             usage: TokenUsage(input: 2000, output: 1000),
                                             cost: 0.02)

        var day2 = DailyAggregate(day: "2025-07-15")
        day2.perModel["haiku"] = ModelUsage(model: "haiku", rawModel: "claude-haiku-4-5",
                                            usage: TokenUsage(input: 5000, output: 3000),
                                            cost: 0.01)

        return ["2025-07-14": day1, "2025-07-15": day2]
    }

    func testCSVHasHeaderRow() {
        let data = UsageExporter.csvData(from: sampleAggregates())
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "Day,Model,Input Tokens,Output Tokens,Cache Read,Cache Write 5m,Cache Write 1h,Cost")
    }

    func testCSVRowCountMatchesModelDayPairs() {
        let data = UsageExporter.csvData(from: sampleAggregates())
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        // 1 header + 2 models day1 + 1 model day2 = 4
        XCTAssertEqual(lines.count, 4)
    }

    func testCSVSortedByDay() {
        let data = UsageExporter.csvData(from: sampleAggregates())
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        // Skip header; first data row is day1, last is day2
        XCTAssertTrue(lines[1].hasPrefix("2025-07-14"))
        XCTAssertTrue(lines[3].hasPrefix("2025-07-15"))
    }

    func testCSVCostFormattedAsMachineReadable() {
        let data = UsageExporter.csvData(from: sampleAggregates())
        let csv = String(data: data, encoding: .utf8)!
        XCTAssertTrue(csv.contains("0.050000"))
    }

    func testJSONRoundTrips() throws {
        let aggregates = sampleAggregates()
        let data = try UsageExporter.jsonData(from: aggregates)
        let decoded = try JSONDecoder().decode([ExportDay].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].day, "2025-07-14")
        XCTAssertEqual(decoded[1].day, "2025-07-15")
        XCTAssertEqual(decoded[0].models.first { $0.model == "opus" }?.cost, 0.05)
    }

    func testJSONCostRoundedToSixDecimalPlaces() throws {
        // 0.1 + 0.2 in IEEE 754 produces 0.30000000000000004 — verify it's rounded in JSON output
        var day = DailyAggregate(day: "2025-07-14")
        day.perModel["m"] = ModelUsage(model: "m", rawModel: "r",
                                       usage: TokenUsage(input: 1, output: 1),
                                       cost: 0.1 + 0.2)
        let data = try UsageExporter.jsonData(from: ["2025-07-14": day])
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("0.30000000000000"), "cost must not bleed floating-point noise into JSON")
        let decoded = try JSONDecoder().decode([ExportDay].self, from: data)
        XCTAssertEqual(decoded[0].models[0].cost, 0.3, accuracy: 0.0000001)
    }

    func testExportEmptyAggregatesProducesHeaderOnly() {
        let data = UsageExporter.csvData(from: [:])
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], "Day,Model,Input Tokens,Output Tokens,Cache Read,Cache Write 5m,Cache Write 1h,Cost")
    }
}
