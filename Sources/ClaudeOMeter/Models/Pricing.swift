import Foundation

/// Prices are USD per **one million** tokens.
struct ModelPrice: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var fastMultiplier: Double?
    var longContextThreshold: Int? = nil
    var longContext: LongContextPrice? = nil
}

/// Full-request token rates used when the prompt exceeds a model's long-context threshold.
/// Prices are USD per one million tokens; output does not count toward the threshold.
struct LongContextPrice: Codable, Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
}

/// A complete model price that applies to usage on or after a UTC day.
/// `effectiveFrom` is a `YYYY-MM-DD` calendar date in UTC.
struct DatedModelPrice: Codable, Sendable, Equatable {
    var effectiveFrom: String
    var price: ModelPrice
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
    /// merge bundled defaults on next launch while preserving user edits.
    var version: Int?
    /// Cost per web search request in USD.
    var webSearchCost: Double?
    /// Multiplicative surcharge for US-only/domestic-pinned inference, e.g. 1.1 = 10% surcharge.
    var usOnlyMultiplier: Double?
    /// Dated price revisions per model key. Each key must also exist in `models`,
    /// which holds the base price used before the key's first revision and when no day is supplied.
    var modelPriceHistory: [String: [DatedModelPrice]]? = nil

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
            // Bedrock Mantle regional Standard rates. [1m] changes capacity, not billing.
            // Sol supports only a 30-minute TTL; both transcript cache-write buckets use its single write tariff.
            "bedrock_mantle/openai.gpt-6.1-sol": ModelPrice(
                input: 2.2, output: 11, cacheRead: 0.11, cacheWrite5m: 2.75, cacheWrite1h: 2.75,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 4.4, output: 16.5, cacheRead: 0.22, cacheWrite5m: 5.5, cacheWrite1h: 5.5)),
            "bedrock_mantle/openai.gpt-6.1-sol[1m]": ModelPrice(
                input: 2.2, output: 11, cacheRead: 0.11, cacheWrite5m: 2.75, cacheWrite1h: 2.75,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 4.4, output: 16.5, cacheRead: 0.22, cacheWrite5m: 5.5, cacheWrite1h: 5.5)),
            // GPT-6 Luna and Sol on the same Mantle regional route as GPT-6.1 Sol. Official sources:
            // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html and
            // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-sol.html.
            // Mantle supports only a 30-minute cache TTL. The cacheWrite1h fields hold that same rate
            // because the field names follow the Anthropic-shaped transcript buckets.
            "bedrock_mantle/openai.gpt-6-luna": ModelPrice(
                input: 0.11, output: 0.55, cacheRead: 0.011, cacheWrite5m: 0.1375, cacheWrite1h: 0.1375,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 0.22, output: 0.825, cacheRead: 0.022, cacheWrite5m: 0.275, cacheWrite1h: 0.275)),
            "bedrock_mantle/openai.gpt-6-luna[1m]": ModelPrice(
                input: 0.11, output: 0.55, cacheRead: 0.011, cacheWrite5m: 0.1375, cacheWrite1h: 0.1375,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 0.22, output: 0.825, cacheRead: 0.022, cacheWrite5m: 0.275, cacheWrite1h: 0.275)),
            "bedrock_mantle/openai.gpt-6-sol": ModelPrice(
                input: 2.2, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 2.75,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 4.4, output: 16.5, cacheRead: 0.44, cacheWrite5m: 5.5, cacheWrite1h: 5.5)),
            "bedrock_mantle/openai.gpt-6-sol[1m]": ModelPrice(
                input: 2.2, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 2.75,
                longContextThreshold: 272_000,
                longContext: LongContextPrice(input: 4.4, output: 16.5, cacheRead: 0.44, cacheWrite5m: 5.5, cacheWrite1h: 5.5)),
            // Exact-key overrides for deprecated / differently-priced model versions.
            "claude-opus-4-1":   ModelPrice(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30),
            // Exact-key overrides for models priced differently from their family bucket.
            "claude-sonnet-5":   ModelPrice(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4),
            "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4),
            "claude-opus-5-5":   ModelPrice(input: 4, output: 20, cacheRead: 0.20, cacheWrite5m: 5.00, cacheWrite1h: 8, fastMultiplier: 2),
            "claude-opus-5":     ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, fastMultiplier: 2),
            "claude-opus-4-8":   ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, fastMultiplier: 2),
            "claude-fable-5-1":  ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20),
            // Claude Haiku 5.5 long-context tier: a request over 100,000 prompt tokens pays these rates.
            // https://platform.claude.com/docs/en/about-claude/pricing#long-context-pricing
            // https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-5-5.html
            "claude-haiku-5-5": ModelPrice(
                input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2,
                longContextThreshold: 100_000,
                longContext: LongContextPrice(input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite5m: 0.625, cacheWrite1h: 1)),
            // Bedrock US (us.anthropic.*) — 10% regional markup over direct-API rates.
            "us.anthropic.claude-sonnet-5":   ModelPrice(input: 2.20, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 4.40),
            "us.anthropic.claude-sonnet-5-5": ModelPrice(input: 2.20, output: 11, cacheRead: 0.22, cacheWrite5m: 2.75, cacheWrite1h: 4.40),
            "us.anthropic.claude-opus-5-5":   ModelPrice(input: 4.40, output: 22, cacheRead: 0.22, cacheWrite5m: 5.50, cacheWrite1h: 8.80, fastMultiplier: 2),
            "us.anthropic.claude-opus-5":     ModelPrice(input: 5.50, output: 27.50, cacheRead: 0.55, cacheWrite5m: 6.875, cacheWrite1h: 11, fastMultiplier: 2),
            "us.anthropic.claude-opus-4-8":   ModelPrice(input: 5.50, output: 27.50, cacheRead: 0.55, cacheWrite5m: 6.875, cacheWrite1h: 11, fastMultiplier: 2),
            "us.anthropic.claude-fable-5-1":  ModelPrice(input: 11, output: 55, cacheRead: 0.28, cacheWrite5m: 13.75, cacheWrite1h: 22),
            // Haiku 5.5 US rates are 1.1x the direct rates in both tiers.
            "us.anthropic.claude-haiku-5-5": ModelPrice(
                input: 0.11, output: 0.55, cacheRead: 0.011, cacheWrite5m: 0.1375, cacheWrite1h: 0.22,
                longContextThreshold: 100_000,
                longContext: LongContextPrice(input: 0.55, output: 2.75, cacheRead: 0.055, cacheWrite5m: 0.6875, cacheWrite1h: 1.1)),
            // Bedrock global cross-region inference (global.anthropic.*).
            "global.anthropic.claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4),
            "global.anthropic.claude-haiku-5-5": ModelPrice(
                input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.2,
                longContextThreshold: 100_000,
                longContext: LongContextPrice(input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite5m: 0.625, cacheWrite1h: 1)),
        ],
        fallback: ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10),
        discountPercent: 0,
        version: 7,
        webSearchCost: 0.01,
        usOnlyMultiplier: 1.1,
        // AWS cut Claude Sonnet 5.5 cache-read rates by 50% from 2026-10-07. Sources: the AWS Bedrock pricing page
        // (https://aws.amazon.com/bedrock/pricing/) and the model cards
        // (https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5-5.html).
        // The `models` entries keep the pre-change rates. They apply to requests before that day and to requests with no day.
        // The global pre-change cache-read rate (0.20) is derived from the 50% cut, not quoted from a page.
        modelPriceHistory: [
            "us.anthropic.claude-sonnet-5-5": [
                DatedModelPrice(effectiveFrom: "2026-10-07",
                                price: ModelPrice(input: 2.2, output: 11, cacheRead: 0.11, cacheWrite5m: 2.75, cacheWrite1h: 4.4)),
            ],
            "global.anthropic.claude-sonnet-5-5": [
                DatedModelPrice(effectiveFrom: "2026-10-07",
                                price: ModelPrice(input: 2, output: 10, cacheRead: 0.10, cacheWrite5m: 2.5, cacheWrite1h: 4)),
            ],
        ]
    )

    /// Resolves the price for one model. Lookup order: the full lowercased raw key, the key without its
    /// provider prefix, the family, then the fallback. The first match in `models` wins, so an exact key never loses to a family.
    /// `rateDayUTC` (a `YYYY-MM-DD` UTC day) picks the matched key's latest revision on or before that day.
    /// A nil, empty or malformed day, or a day before the first revision, uses the undated base price.
    func price(forFamily family: String, rawModel: String, rateDayUTC: String? = nil) -> ModelPrice? {
        let rawKey = rawModel.lowercased()
        let strippedKey = ModelNormalizer.stripProviderPrefix(rawModel).lowercased()
        let key: String
        if models[rawKey] != nil {
            key = rawKey
        } else if models[strippedKey] != nil {
            key = strippedKey
        } else if models[family] != nil {
            key = family
        } else {
            return fallback
        }
        return revisedPrice(forKey: key, rateDayUTC: rateDayUTC) ?? models[key]
    }

    /// The latest revision of `key` that is effective on or before `rateDayUTC`, or nil when none applies.
    private func revisedPrice(forKey key: String, rateDayUTC: String?) -> ModelPrice? {
        guard let day = rateDayUTC, isValidUTCDay(day), let revisions = modelPriceHistory?[key] else { return nil }
        return revisions
            .filter { $0.effectiveFrom <= day }
            .max { $0.effectiveFrom < $1.effectiveFrom }?
            .price
    }

    /// Cost in USD for a usage bundle attributed to a model family.
    /// For usage summed from requests with the same prompt length, supply that promptTokens value.
    /// Otherwise, all input and cache buckets count toward the threshold, but output does not.
    func cost(of usage: TokenUsage, family: String, rawModel: String, promptTokens: Int? = nil,
              rateDayUTC: String? = nil) -> Double {
        guard family != ModelNormalizer.syntheticFamily,
              let p = price(forFamily: family, rawModel: rawModel, rateDayUTC: rateDayUTC) else { return 0 }
        let promptCount = promptTokens ?? usage.promptTokens
        let longRates: LongContextPrice?
        if let threshold = p.longContextThreshold, promptCount > threshold {
            longRates = p.longContext
        } else {
            longRates = nil
        }
        let m = 1_000_000.0
        let inputCost    = Double(usage.input)        / m * (longRates?.input ?? p.input)
        let outputCost   = Double(usage.output)       / m * (longRates?.output ?? p.output)
        let cacheRdCost  = Double(usage.cacheRead)    / m * (longRates?.cacheRead ?? p.cacheRead)
        let cache5mCost  = Double(usage.cacheWrite5m) / m * (longRates?.cacheWrite5m ?? p.cacheWrite5m)
        let cache1hCost  = Double(usage.cacheWrite1h) / m * (longRates?.cacheWrite1h ?? p.cacheWrite1h)
        let webCost      = Double(usage.webSearchRequests) * (webSearchCost ?? 0)
        let base = inputCost + outputCost + cacheRdCost + cache5mCost + cache1hCost + webCost
        return base * discountMultiplier
    }

    /// Exact lowercased Mantle routes whose regional Standard prices already include the domestic premium.
    static let regionalOpenAIRoutes: Set<String> = [
        "bedrock_mantle/openai.gpt-6.1-sol", "bedrock_mantle/openai.gpt-6.1-sol[1m]",
        "bedrock_mantle/openai.gpt-6-sol", "bedrock_mantle/openai.gpt-6-sol[1m]",
        "bedrock_mantle/openai.gpt-6-luna", "bedrock_mantle/openai.gpt-6-luna[1m]",
    ]

    /// Combined multiplicative surcharge for fast-mode and domestic inference.
    ///
    /// Bedrock US Anthropic prices and the exact regional Mantle OpenAI routes include a regional premium.
    /// Exclude domestic inference for these routes to avoid charging the premium twice.
    func surchargeMultiplier(family: String, rawModel: String, isFast: Bool, isDomestic: Bool,
                             rateDayUTC: String? = nil) -> Double {
        let p = price(forFamily: family, rawModel: rawModel, rateDayUTC: rateDayUTC)
        let rawKey = rawModel.lowercased()
        let isRegionalOpenAI = Self.regionalOpenAIRoutes.contains(rawKey)
        let isBedrockRegionPriced = isRegionalOpenAI
            || ModelNormalizer.stripProviderPrefix(rawModel).lowercased().hasPrefix("us.anthropic.")
        let fast = (isFast ? (p?.fastMultiplier ?? 1) : 1)
        let domestic = (isDomestic && !isBedrockRegionPriced) ? (usOnlyMultiplier ?? 1) : 1
        return fast * domestic
    }
}

/// True for a real calendar date written as `YYYY-MM-DD` (ASCII digits only, leap years handled).
fileprivate func isValidUTCDay(_ day: String) -> Bool {
    let parts = day.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
          let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
          (1...12).contains(month) else { return false }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    return (1...daysInMonth).contains(dayOfMonth)
}

extension PricingTable {
    /// Decodes a table and rejects an invalid `modelPriceHistory` instead of ignoring it.
    /// Tables without history decode as before, because the new field is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decode([String: ModelPrice].self, forKey: .models)
        fallback = try c.decodeIfPresent(ModelPrice.self, forKey: .fallback)
        discountPercent = try c.decodeIfPresent(Double.self, forKey: .discountPercent)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        webSearchCost = try c.decodeIfPresent(Double.self, forKey: .webSearchCost)
        usOnlyMultiplier = try c.decodeIfPresent(Double.self, forKey: .usOnlyMultiplier)
        modelPriceHistory = try c.decodeIfPresent([String: [DatedModelPrice]].self, forKey: .modelPriceHistory)
        try validateHistory(modelPriceHistory, in: c)
    }

    /// Checks each revision list. Keys must be lowercase and exist in `models`, so a revision
    /// never hides a base price that a reader cannot see. Each day must be a real `YYYY-MM-DD`,
    /// and no two revisions of one key may share a day. Revised rates must be finite and nonnegative.
    private func validateHistory(_ history: [String: [DatedModelPrice]]?,
                                 in c: KeyedDecodingContainer<CodingKeys>) throws {
        guard let history else { return }
        for (key, revisions) in history {
            let path = c.codingPath
            guard key == key.lowercased() else {
                throw DecodingError.dataCorrupted(.init(codingPath: path,
                    debugDescription: "modelPriceHistory key '\(key)' must be lowercase"))
            }
            guard models[key] != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: path,
                    debugDescription: "modelPriceHistory key '\(key)' has no base price in models"))
            }
            var seenDays = Set<String>()
            for revision in revisions {
                guard isValidUTCDay(revision.effectiveFrom) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: path,
                        debugDescription: "modelPriceHistory '\(key)' has invalid effectiveFrom '\(revision.effectiveFrom)'"))
                }
                guard seenDays.insert(revision.effectiveFrom).inserted else {
                    throw DecodingError.dataCorrupted(.init(codingPath: path,
                        debugDescription: "modelPriceHistory '\(key)' repeats effectiveFrom '\(revision.effectiveFrom)'"))
                }
                try revision.price.validateRates(path: path, key: key)
            }
        }
    }
}

extension ModelPrice {
    /// Rejects a negative or non-finite rate, a negative long-context threshold, and a tier with no threshold (or the reverse).
    fileprivate func validateRates(path: [CodingKey], key: String) throws {
        let rates = [input, output, cacheRead, cacheWrite5m, cacheWrite1h, fastMultiplier ?? 0]
        guard rates.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path,
                debugDescription: "modelPriceHistory '\(key)' has a negative or non-finite rate"))
        }
        guard (longContextThreshold == nil) == (longContext == nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path,
                debugDescription: "modelPriceHistory '\(key)' sets longContext without longContextThreshold, or the reverse"))
        }
        // Zero is allowed: the tier applies when the prompt is strictly greater than the threshold.
        if let threshold = longContextThreshold, threshold < 0 {
            throw DecodingError.dataCorrupted(.init(codingPath: path,
                debugDescription: "modelPriceHistory '\(key)' has a negative longContextThreshold"))
        }
        if let tier = longContext {
            let tierRates = [tier.input, tier.output, tier.cacheRead, tier.cacheWrite5m, tier.cacheWrite1h]
            guard tierRates.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path,
                    debugDescription: "modelPriceHistory '\(key)' has a negative or non-finite long-context rate"))
            }
        }
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
