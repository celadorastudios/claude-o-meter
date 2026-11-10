import Foundation

/// Token counts for a single message or an aggregate, broken out by billing tier.
struct TokenUsage: Codable, Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0
    var webSearchRequests: Int = 0

    /// Full prompt length from disjoint fresh-input and cache buckets; excludes output.
    var promptTokens: Int { input + cacheRead + cacheWrite5m + cacheWrite1h }
    var total: Int { promptTokens + output }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            webSearchRequests: lhs.webSearchRequests + rhs.webSearchRequests
        )
    }

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0,
         cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, webSearchRequests: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.webSearchRequests = webSearchRequests
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input             = (try? c.decodeIfPresent(Int.self, forKey: .input))             ?? 0
        output            = (try? c.decodeIfPresent(Int.self, forKey: .output))            ?? 0
        cacheRead         = (try? c.decodeIfPresent(Int.self, forKey: .cacheRead))         ?? 0
        cacheWrite5m      = (try? c.decodeIfPresent(Int.self, forKey: .cacheWrite5m))      ?? 0
        cacheWrite1h      = (try? c.decodeIfPresent(Int.self, forKey: .cacheWrite1h))      ?? 0
        webSearchRequests = (try? c.decodeIfPresent(Int.self, forKey: .webSearchRequests)) ?? 0
    }
    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite5m, cacheWrite1h, webSearchRequests
    }
}

/// A single deduplicated usage event extracted from a transcript line.
struct UsageRecord: Sendable, Equatable {
    let id: String          // message.id — global dedup key
    let day: String         // local calendar day, "yyyy-MM-dd"
    let hour: Int           // 0-23, local time
    let model: String       // normalized family, e.g. "opus" / "sonnet" / "haiku"
    let rawModel: String    // original model string (for reference)
    let usage: TokenUsage
    let projectDir: String  // encoded directory name under ~/.claude/projects/
    let isFast: Bool        // usage.speed == "fast"
    let isDomestic: Bool    // usage.inference_geo == "us"
    /// UTC calendar day of the original request, "yyyy-MM-dd". Empty when the transcript did not
    /// supply it. It is never inferred from `day`, which is a local day.
    let rateDayUTC: String

    init(id: String, day: String, hour: Int, model: String, rawModel: String,
         usage: TokenUsage, projectDir: String, isFast: Bool = false, isDomestic: Bool = false,
         rateDayUTC: String = "") {
        self.id = id; self.day = day; self.hour = hour; self.model = model
        self.rawModel = rawModel; self.usage = usage; self.projectDir = projectDir
        self.isFast = isFast; self.isDomestic = isDomestic; self.rateDayUTC = rateDayUTC
    }
}

/// Groups usage that shares every input the price depends on: family, raw model, UTC rate day,
/// prompt length, and the fast and domestic flags. Holds no record ID, text or full timestamp.
struct PricingUsageKey: Codable, Hashable, Sendable {
    let family: String
    let rawModel: String
    let rateDayUTC: String
    let promptTokens: Int
    let isFast: Bool
    let isDomestic: Bool

    init(family: String, rawModel: String, rateDayUTC: String, promptTokens: Int,
         isFast: Bool, isDomestic: Bool) {
        self.family = family; self.rawModel = rawModel; self.rateDayUTC = rateDayUTC
        self.promptTokens = promptTokens; self.isFast = isFast; self.isDomestic = isDomestic
    }

    init(record: UsageRecord) {
        self.init(family: record.model, rawModel: record.rawModel, rateDayUTC: record.rateDayUTC,
                  promptTokens: record.usage.promptTokens, isFast: record.isFast,
                  isDomestic: record.isDomestic)
    }
}

/// Cost breakdown for one hour of a single day. Computed on demand; never persisted.
struct HourlySlice: Sendable, Identifiable {
    let hour: Int           // 0-23
    var cost: Double = 0
    var perModel: [String: Double] = [:]
    var id: Int { hour }
}

/// Per-model usage + computed cost within a single day.
struct ModelUsage: Codable, Sendable, Equatable {
    var model: String
    var rawModel: String = ""
    var usage: TokenUsage = TokenUsage()
    var cost: Double = 0
    var surchargeUSD: Double = 0
    /// Usage broken out by exact raw model string, so `recost` can reprice each raw model's
    /// own slice independently instead of repricing the cumulative `usage` under a single
    /// `rawModel` — needed whenever a day mixes two differently-priced raw models under the
    /// same family (e.g. direct-API + Bedrock-routed calls for the same model). Empty for
    /// aggregates folded before this field existed; `recost` falls back to the old
    /// single-rawModel approximation in that case (repaired by the next full re-fold).
    var perRawModelUsage: [String: TokenUsage] = [:]

    /// Raw model → original request prompt token count → summed usage of requests with that count.
    /// Collected for routes tiered in current or bundled pricing, even if custom pricing disables a tier.
    /// Daily token sums cannot select a request's tier, and editable thresholds can change it.
    var perRawModelPromptUsage: [String: [Int: TokenUsage]] = [:]
    /// Token totals grouped by the original pricing inputs, for accurate recalculation.
    /// Legacy aggregates without these groups use raw-model and prompt-length approximations
    /// and preserve their stored surcharge dollars until a full re-fold supplies the missing inputs.
    var pricingUsage: [PricingUsageKey: TokenUsage] = [:]

    init(model: String, rawModel: String = "", usage: TokenUsage = TokenUsage(), cost: Double = 0,
         surchargeUSD: Double = 0, perRawModelUsage: [String: TokenUsage] = [:],
         perRawModelPromptUsage: [String: [Int: TokenUsage]] = [:],
         pricingUsage: [PricingUsageKey: TokenUsage] = [:]) {
        self.model = model; self.rawModel = rawModel; self.usage = usage; self.cost = cost
        self.surchargeUSD = surchargeUSD; self.perRawModelUsage = perRawModelUsage
        self.perRawModelPromptUsage = perRawModelPromptUsage; self.pricingUsage = pricingUsage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model            = try  c.decode(String.self,     forKey: .model)
        rawModel         = (try? c.decodeIfPresent(String.self,     forKey: .rawModel))         ?? ""
        usage            = (try? c.decodeIfPresent(TokenUsage.self, forKey: .usage))            ?? TokenUsage()
        cost             = (try? c.decodeIfPresent(Double.self,     forKey: .cost))              ?? 0
        surchargeUSD     = (try? c.decodeIfPresent(Double.self,     forKey: .surchargeUSD))      ?? 0
        perRawModelUsage = (try? c.decodeIfPresent([String: TokenUsage].self, forKey: .perRawModelUsage)) ?? [:]
        perRawModelPromptUsage = (try? c.decodeIfPresent([String: [Int: TokenUsage]].self, forKey: .perRawModelPromptUsage)) ?? [:]
        pricingUsage     = (try? c.decodeIfPresent([PricingUsageKey: TokenUsage].self, forKey: .pricingUsage)) ?? [:]
    }
    private enum CodingKeys: String, CodingKey {
        case model, rawModel, usage, cost, surchargeUSD, perRawModelUsage, perRawModelPromptUsage, pricingUsage
    }
}

/// Per-project cost + model breakdown for one day. Accumulated incrementally from scan records.
/// `pricingUsage` keeps the token totals behind `cost`, so `recost` can reprice this project after
/// a pricing change. Without it, the project's cost could only be kept as dollars, which cannot be repriced.
struct ProjectUsage: Codable, Sendable, Equatable {
    var cost: Double = 0
    var perModel: [String: Double] = [:]   // model family → cost
    /// model family → avoidable cache-read tokens re-read above the healthy context cap (context tax).
    var taxableCacheRead: [String: Int] = [:]
    /// Token totals per `PricingUsageKey` for this project. Empty for projects folded before this
    /// field existed; those keep their stored `cost`.
    var pricingUsage: [PricingUsageKey: TokenUsage] = [:]

    init(cost: Double = 0, perModel: [String: Double] = [:], taxableCacheRead: [String: Int] = [:],
         pricingUsage: [PricingUsageKey: TokenUsage] = [:]) {
        self.cost = cost; self.perModel = perModel; self.taxableCacheRead = taxableCacheRead
        self.pricingUsage = pricingUsage
    }
    // Custom decoder so old state.json (no taxableCacheRead) decodes without throwing, which would
    // otherwise cascade to the enclosing [String:ProjectUsage] decode and wipe all perProject data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cost             = (try? c.decodeIfPresent(Double.self,          forKey: .cost))             ?? 0
        perModel         = (try? c.decodeIfPresent([String: Double].self, forKey: .perModel))         ?? [:]
        taxableCacheRead = (try? c.decodeIfPresent([String: Int].self,   forKey: .taxableCacheRead)) ?? [:]
        pricingUsage     = (try? c.decodeIfPresent([PricingUsageKey: TokenUsage].self, forKey: .pricingUsage)) ?? [:]
    }
    private enum CodingKeys: String, CodingKey { case cost, perModel, taxableCacheRead, pricingUsage }
}

/// All usage for one local calendar day.
struct DailyAggregate: Codable, Sendable, Equatable {
    var day: String
    var perModel: [String: ModelUsage] = [:]
    /// Encoded project dir → usage for this day. Accumulated incrementally. Each project keeps its
    /// `pricingUsage` token totals, so a pricing change reprices projects the same way as models.
    var perProject: [String: ProjectUsage] = [:]
    /// model family → avoidable cache-read tokens re-read above the healthy context cap (context tax).
    /// Stored as tokens (not dollars) so it reprices for free when pricing.json changes.
    var taxableCacheRead: [String: Int] = [:]

    // Custom decoder so old state.json with perProject:[String:Double] degrades gracefully to [:].
    init(day: String) { self.day = day }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day      = try c.decode(String.self, forKey: .day)
        perModel = try c.decode([String: ModelUsage].self, forKey: .perModel)
        perProject = (try? c.decode([String: ProjectUsage].self, forKey: .perProject)) ?? [:]
        taxableCacheRead = (try? c.decodeIfPresent([String: Int].self, forKey: .taxableCacheRead)) ?? [:]
    }
    private enum CodingKeys: String, CodingKey { case day, perModel, perProject, taxableCacheRead }

    var totalCost: Double { perModel.values.reduce(0) { $0 + $1.cost } }
    var totalTokens: Int { perModel.values.reduce(0) { $0 + $1.usage.total } }

    var sortedModels: [ModelUsage] {
        perModel.values.sorted { $0.cost > $1.cost }
    }
}

/// Concurrency stats for a single calendar day, computed fresh each scan cycle.
struct ConcurrencyStats: Codable, Sendable, Equatable {
    var peakUserSessions: Int = 0
    var peakSubagents: Int = 0
    var peakProjectNames: [String] = []
}

/// User-configurable alert thresholds (USD). nil = disabled.
struct AlertSettings: Codable, Sendable, Equatable {
    var dailyThreshold: Double? = nil
    var monthlyThreshold: Double? = nil
    var tipsEnabled: Bool = true
    /// Percentage of the limit at which the "approaching" notification fires (1–99).
    var approachPercent: Int = 80
    /// User override for the Claude config directory whose `projects/` folder is scanned.
    /// nil / empty = use `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`. See `ProjectsRoot.resolve`.
    var projectsConfigDirOverride: String? = nil

    init(dailyThreshold: Double? = nil, monthlyThreshold: Double? = nil,
         tipsEnabled: Bool = true, approachPercent: Int = 80,
         projectsConfigDirOverride: String? = nil) {
        self.dailyThreshold = dailyThreshold; self.monthlyThreshold = monthlyThreshold
        self.tipsEnabled = tipsEnabled; self.approachPercent = approachPercent
        self.projectsConfigDirOverride = projectsConfigDirOverride
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyThreshold   = try? c.decodeIfPresent(Double.self, forKey: .dailyThreshold)
        monthlyThreshold = try? c.decodeIfPresent(Double.self, forKey: .monthlyThreshold)
        tipsEnabled      = (try? c.decodeIfPresent(Bool.self,  forKey: .tipsEnabled))    ?? true
        approachPercent  = (try? c.decodeIfPresent(Int.self,   forKey: .approachPercent)) ?? 80
        projectsConfigDirOverride = try? c.decodeIfPresent(String.self, forKey: .projectsConfigDirOverride)
    }
    private enum CodingKeys: String, CodingKey {
        case dailyThreshold, monthlyThreshold, tipsEnabled, approachPercent, projectsConfigDirOverride
    }
}
