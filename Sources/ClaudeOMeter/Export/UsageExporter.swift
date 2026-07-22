import Foundation

enum ExportFormat: String, Sendable {
    case csv, json
}

enum UsageExporter {
    static func export(format: ExportFormat, from aggregates: [String: DailyAggregate]) throws -> Data {
        switch format {
        case .csv: return csvData(from: aggregates)
        case .json: return try jsonData(from: aggregates)
        }
    }

    static func csvData(from aggregates: [String: DailyAggregate]) -> Data {
        var lines: [String] = ["Day,Model,Input Tokens,Output Tokens,Cache Read,Cache Write 5m,Cache Write 1h,Cost"]

        let sorted = aggregates.values.sorted { $0.day < $1.day }
        for agg in sorted {
            for model in agg.perModel.values.sorted(by: { $0.model < $1.model }) {
                let u = model.usage
                let cost = String(format: "%.6f", model.cost)
                lines.append("\(csvEscape(agg.day)),\(csvEscape(model.model)),\(u.input),\(u.output),\(u.cacheRead),\(u.cacheWrite5m),\(u.cacheWrite1h),\(cost)")
            }
        }

        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func jsonData(from aggregates: [String: DailyAggregate]) throws -> Data {
        let sorted = aggregates.values.sorted { $0.day < $1.day }
        let exportable = sorted.map { ExportDay(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportable)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

// MARK: - JSON export shape (excludes internal fields)

struct ExportDay: Codable {
    let day: String
    let totalCost: Double
    let models: [ExportModel]

    init(from agg: DailyAggregate) {
        day = agg.day
        totalCost = (agg.totalCost * 1_000_000).rounded() / 1_000_000
        models = agg.perModel.values
            .sorted { $0.model < $1.model }
            .map { ExportModel(from: $0) }
    }
}

struct ExportModel: Codable {
    let model: String
    let cost: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int

    init(from mu: ModelUsage) {
        model = mu.model
        cost = (mu.cost * 1_000_000).rounded() / 1_000_000
        inputTokens = mu.usage.input
        outputTokens = mu.usage.output
        cacheReadTokens = mu.usage.cacheRead
        cacheWrite5mTokens = mu.usage.cacheWrite5m
        cacheWrite1hTokens = mu.usage.cacheWrite1h
    }
}
