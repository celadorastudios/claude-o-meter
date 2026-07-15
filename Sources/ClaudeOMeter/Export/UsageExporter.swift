import Foundation

enum ExportFormat: String, Sendable {
    case csv, json
}

enum UsageExporter {
    static func csvData(from aggregates: [String: DailyAggregate]) -> Data {
        var lines: [String] = ["Day,Model,Input Tokens,Output Tokens,Cache Read,Cache Write 5m,Cache Write 1h,Cost"]

        let sorted = aggregates.values.sorted { $0.day < $1.day }
        for agg in sorted {
            for model in agg.perModel.values.sorted(by: { $0.model < $1.model }) {
                let u = model.usage
                let cost = String(format: "%.6f", model.cost)
                lines.append("\(agg.day),\(csvEscape(model.model)),\(u.input),\(u.output),\(u.cacheRead),\(u.cacheWrite5m),\(u.cacheWrite1h),\(cost)")
            }
        }

        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func jsonData(from aggregates: [String: DailyAggregate]) throws -> Data {
        let sorted = aggregates.values.sorted { $0.day < $1.day }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sorted)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
