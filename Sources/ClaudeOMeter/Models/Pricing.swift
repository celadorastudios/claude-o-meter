import Foundation

/// Prices are USD per **one million** tokens.
struct ModelPrice: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
}

/// Pricing table keyed by normalized model *family* ("opus"/"sonnet"/"haiku"),
/// with optional exact-key overrides and a fallback for unknown models.
struct PricingTable: Codable, Sendable, Equatable {
    /// Keyed by family or exact normalized model name.
    var models: [String: ModelPrice]
    var fallback: ModelPrice?
    /// Flat enterprise/committed-use discount applied to every computed cost, e.g. 15 = 15% off.
    var discountPercent: Double?
    /// Monotonically increasing integer. When the bundled version exceeds the installed version,
    /// the installed pricing.json is auto-replaced (preserving discountPercent) on next launch.
    var version: Int?

    private var discountMultiplier: Double {
        let pct = max(0, min(100, discountPercent ?? 0))
        return 1 - pct / 100
    }

    static let `default` = PricingTable(
        models: [
            // Anthropic API rates (USD / 1M tokens). Bedrock on-demand may differ —
            // edit pricing.json to match your exact contract or use discountPercent for a flat adjustment.
            "fable":  ModelPrice(input: 10,  output: 50, cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20),
            "opus":   ModelPrice(input: 5,   output: 25, cacheRead: 0.50, cacheWrite5m: 6.25,  cacheWrite1h: 10),
            "sonnet": ModelPrice(input: 3,   output: 15, cacheRead: 0.30, cacheWrite5m: 3.75,  cacheWrite1h: 6),
            "haiku":  ModelPrice(input: 1,   output: 5,  cacheRead: 0.10, cacheWrite5m: 1.25,  cacheWrite1h: 2),
            "luna":   ModelPrice(input: 1.1, output: 6.6, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            "terra":  ModelPrice(input: 2.75, output: 16.5, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            "sol":    ModelPrice(input: 5.5, output: 33, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0),
            // Exact-key overrides for deprecated / differently-priced model versions.
            "claude-opus-4-1": ModelPrice(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
        ],
        fallback: ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10),
        discountPercent: 0,
        version: 3
    )

    func price(forFamily family: String, rawModel: String) -> ModelPrice? {
        if let exact = models[rawModel.lowercased()] { return exact }
        if let fam = models[family] { return fam }
        return fallback
    }

    /// Cost in USD for a usage bundle attributed to a model family.
    func cost(of usage: TokenUsage, family: String, rawModel: String) -> Double {
        guard family != ModelNormalizer.syntheticFamily,
              let p = price(forFamily: family, rawModel: rawModel) else { return 0 }
        let m = 1_000_000.0
        let base = Double(usage.input)        / m * p.input
                 + Double(usage.output)       / m * p.output
                 + Double(usage.cacheRead)    / m * p.cacheRead
                 + Double(usage.cacheWrite5m) / m * p.cacheWrite5m
                 + Double(usage.cacheWrite1h) / m * p.cacheWrite1h
        return base * discountMultiplier
    }
}

/// Maps raw model strings (incl. Bedrock/Vertex prefixes & version suffixes) to a stable family.
enum ModelNormalizer {
    static let syntheticFamily = "synthetic"

    static func family(for rawModel: String) -> String {
        let m = rawModel.lowercased()
        if m.contains("synthetic") { return syntheticFamily }
        if m.contains("fable") || m.contains("mythos") { return "fable" }
        if m.contains("opus") { return "opus" }
        if m.contains("sonnet") { return "sonnet" }
        if m.contains("haiku") { return "haiku" }
        if m.contains("luna") { return "luna" }
        if m.contains("terra") { return "terra" }
        if m.contains("sol") { return "sol" }
        return "unknown"
    }
}
