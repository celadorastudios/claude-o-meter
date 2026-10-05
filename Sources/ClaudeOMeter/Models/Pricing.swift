import Foundation

/// Prices are USD per **one million** tokens.
struct ModelPrice: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var fastMultiplier: Double?
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
    /// Cost per web search request in USD.
    var webSearchCost: Double?
    /// Multiplicative surcharge for US-only/domestic-pinned inference, e.g. 1.1 = 10% surcharge.
    var usOnlyMultiplier: Double?

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
            "claude-opus-4-1":   ModelPrice(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
            // Exact-key overrides for models priced differently from their family bucket.
            "claude-sonnet-5":   ModelPrice(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4),
            "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4),
            "claude-opus-5-5":   ModelPrice(input: 4, output: 20, cacheRead: 0.20, cacheWrite5m: 5.00, cacheWrite1h: 8, fastMultiplier: 2),
            "claude-opus-5":     ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, fastMultiplier: 2),
            "claude-opus-4-8":   ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, fastMultiplier: 2),
            "claude-fable-5-1":  ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
            // Bedrock US (us.anthropic.*) — 10% regional markup over direct-API rates.
            "us.anthropic.claude-sonnet-5":   ModelPrice(input: 2.20, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 4.40),
            "us.anthropic.claude-sonnet-5-5": ModelPrice(input: 2.20, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 4.40),
            "us.anthropic.claude-opus-5-5":   ModelPrice(input: 4.40, output: 22, cacheRead: 0.22, cacheWrite5m: 5.50, cacheWrite1h: 8.80, fastMultiplier: 2),
            "us.anthropic.claude-opus-5":     ModelPrice(input: 5.50, output: 27.50, cacheRead: 0.55, cacheWrite5m: 6.875, cacheWrite1h: 11, fastMultiplier: 2),
            "us.anthropic.claude-opus-4-8":   ModelPrice(input: 5.50, output: 27.50, cacheRead: 0.55, cacheWrite5m: 6.875, cacheWrite1h: 11, fastMultiplier: 2),
            "us.anthropic.claude-fable-5-1":  ModelPrice(input: 11, output: 55, cacheRead: 0.28, cacheWrite5m: 13.75, cacheWrite1h: 22),
        ],
        fallback: ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10),
        discountPercent: 0,
        version: 4,
        webSearchCost: 0.01,
        usOnlyMultiplier: 1.1
    )

    func price(forFamily family: String, rawModel: String) -> ModelPrice? {
        let stripped = ModelNormalizer.stripProviderPrefix(rawModel)
        if let exact = models[stripped.lowercased()] { return exact }
        if let exact = models[rawModel.lowercased()] { return exact }
        if let fam = models[family] { return fam }
        return fallback
    }

    /// Cost in USD for a usage bundle attributed to a model family.
    func cost(of usage: TokenUsage, family: String, rawModel: String) -> Double {
        guard family != ModelNormalizer.syntheticFamily,
              let p = price(forFamily: family, rawModel: rawModel) else { return 0 }
        let m = 1_000_000.0
        let inputCost    = Double(usage.input)        / m * p.input
        let outputCost   = Double(usage.output)       / m * p.output
        let cacheRdCost  = Double(usage.cacheRead)    / m * p.cacheRead
        let cache5mCost  = Double(usage.cacheWrite5m) / m * p.cacheWrite5m
        let cache1hCost  = Double(usage.cacheWrite1h) / m * p.cacheWrite1h
        let webCost      = Double(usage.webSearchRequests) * (webSearchCost ?? 0)
        let base = inputCost + outputCost + cacheRdCost + cache5mCost + cache1hCost + webCost
        return base * discountMultiplier
    }

    /// Combined multiplicative surcharge for fast-mode and domestic inference.
    ///
    /// `isDomestic` is excluded here when `rawModel` already resolved to a Bedrock-region exact-key
    /// price (`us.anthropic.*`), which already bakes in its own regional markup — applying
    /// `usOnlyMultiplier` on top would double-charge the same real-world surcharge. In practice the two
    /// signals haven't been observed to co-occur on a single record (Bedrock-routed calls don't appear
    /// to populate `inference_geo`), but nothing guarantees that stays true, so this guard is defensive.
    func surchargeMultiplier(family: String, rawModel: String, isFast: Bool, isDomestic: Bool) -> Double {
        let p = price(forFamily: family, rawModel: rawModel)
        let isBedrockRegionPriced = ModelNormalizer.stripProviderPrefix(rawModel).lowercased().hasPrefix("us.anthropic.")
        let fast = (isFast ? (p?.fastMultiplier ?? 1) : 1)
        let domestic = (isDomestic && !isBedrockRegionPriced) ? (usOnlyMultiplier ?? 1) : 1
        return fast * domestic
    }
}

/// Maps raw model strings (incl. Bedrock/Vertex prefixes & version suffixes) to a stable family.
enum ModelNormalizer {
    static let syntheticFamily = "synthetic"

    /// Strip the outermost provider-routing prefix (the `…/` segment before the model
    /// identifier) so that region-qualified Bedrock ARNs like
    /// `us.anthropic.claude-sonnet-5` survive for exact-key pricing lookup.
    /// Examples:
    ///   "bedrock/us.anthropic.claude-sonnet-5"  →  "us.anthropic.claude-sonnet-5"
    ///   "vertex_ai/claude-sonnet-5"             →  "claude-sonnet-5"
    ///   "claude-sonnet-5"                       →  "claude-sonnet-5"  (no-op)
    static func stripProviderPrefix(_ rawModel: String) -> String {
        guard let slashIdx = rawModel.firstIndex(of: "/") else { return rawModel }
        return String(rawModel[rawModel.index(after: slashIdx)...])
    }

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
