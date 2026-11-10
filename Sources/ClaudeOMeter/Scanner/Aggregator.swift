import Foundation

/// Pure folding of usage records into per-day aggregates. Kept separate from the store
/// so it is trivially testable.
enum Aggregator {
    /// Healthy live-context cap (tokens). A disciplined session rarely needs more; above this,
    /// the cache-read that re-reads the older context is avoidable "context tax".
    static let healthyContextCap = 200_000

    /// Avoidable cache-read tokens on a single turn: the fraction of this turn's cache-read that
    /// re-read context above `healthyContextCap`. Non-linear per turn, so it must be accumulated at
    /// fold time — it cannot be reconstructed from summed daily aggregates. Zero for synthetic turns,
    /// turns with no cache-read, or turns whose whole context is under the cap.
    static func taxableCacheRead(for rec: UsageRecord) -> Int {
        guard rec.model != ModelNormalizer.syntheticFamily else { return 0 }
        let u = rec.usage
        guard u.cacheRead > 0 else { return 0 }
        let ctx = u.promptTokens
        guard ctx > healthyContextCap else { return 0 }
        let over = Double(ctx - healthyContextCap) / Double(ctx)
        return Int((Double(u.cacheRead) * over).rounded())
    }

    /// Fold new records into `aggregates`, accumulating cost per record.
    static func fold(
        records: [UsageRecord],
        into aggregates: inout [String: DailyAggregate],
        pricing: PricingTable
    ) {
        for rec in records {
            // Move the values out while updating them to avoid copying their growing dictionaries.
            var day = aggregates.removeValue(forKey: rec.day) ?? DailyAggregate(day: rec.day)
            var model = day.perModel.removeValue(forKey: rec.model)
                ?? ModelUsage(model: rec.model, rawModel: rec.rawModel)
            let prevCost = model.cost
            // Keep a legacy aggregate wholly on its approximation path. Adding only the new
            // request's key would make recost omit all usage that predates retained keys.
            let retainsPricingUsage = !model.pricingUsage.isEmpty
                || (model.usage == TokenUsage() && model.cost == 0 && model.surchargeUSD == 0)
            let pricingKey = rec.model == ModelNormalizer.syntheticFamily ? nil : PricingUsageKey(record: rec)
            if retainsPricingUsage, let pricingKey {
                model.pricingUsage[pricingKey, default: TokenUsage()] =
                    model.pricingUsage[pricingKey, default: TokenUsage()] + rec.usage
            }

            let recordBaseCost = pricing.cost(of: rec.usage, family: rec.model, rawModel: rec.rawModel,
                                             rateDayUTC: rec.rateDayUTC)
            let multiplier = pricing.surchargeMultiplier(
                family: rec.model, rawModel: rec.rawModel, isFast: rec.isFast, isDomestic: rec.isDomestic,
                rateDayUTC: rec.rateDayUTC)
            model.surchargeUSD += recordBaseCost * (multiplier - 1)

            model.usage = model.usage + rec.usage
            model.rawModel = rec.rawModel
            model.perRawModelUsage[rec.rawModel, default: TokenUsage()] =
                model.perRawModelUsage[rec.rawModel, default: TokenUsage()] + rec.usage
            // Keep bundled tiered routes complete even while custom pricing disables their tier.
            let currentPrice = pricing.price(forFamily: rec.model, rawModel: rec.rawModel,
                                             rateDayUTC: rec.rateDayUTC)
            let bundledPrice = PricingTable.default.price(forFamily: rec.model, rawModel: rec.rawModel)
            if [currentPrice, bundledPrice].contains(where: {
                $0?.longContextThreshold != nil && $0?.longContext != nil
            }) {
                let promptTokens = rec.usage.promptTokens
                model.perRawModelPromptUsage[rec.rawModel, default: [:]][promptTokens, default: TokenUsage()] =
                    model.perRawModelPromptUsage[rec.rawModel, default: [:]][promptTokens, default: TokenUsage()] + rec.usage
            }
            model.cost += recordBaseCost * multiplier
            day.perModel[rec.model] = model

            let taxable = taxableCacheRead(for: rec)
            if taxable > 0 { day.taxableCacheRead[rec.model, default: 0] += taxable }

            if !rec.projectDir.isEmpty {
                let delta = model.cost - prevCost
                var pu = day.perProject.removeValue(forKey: rec.projectDir) ?? ProjectUsage()
                let retainsProjectPricingUsage = !pu.pricingUsage.isEmpty
                    || (pu.cost == 0 && pu.perModel.keys.allSatisfy { $0 == ModelNormalizer.syntheticFamily })
                if retainsProjectPricingUsage, let pricingKey {
                    pu.pricingUsage[pricingKey, default: TokenUsage()] =
                        pu.pricingUsage[pricingKey, default: TokenUsage()] + rec.usage
                }
                pu.cost += delta
                pu.perModel[rec.model, default: 0] += delta
                if taxable > 0 { pu.taxableCacheRead[rec.model, default: 0] += taxable }
                day.perProject[rec.projectDir] = pu
            }
            aggregates[rec.day] = day
        }
    }

    /// Recompute model and project dollars after a pricing edit, without changing token counts.
    /// Retained keys supply each request's UTC day, prompt length, route and surcharge flags.
    /// Legacy models use raw-model and prompt-length approximations with their stored surcharge;
    /// legacy projects keep stored dollars because they have no repricable token counts.
    static func recost(_ aggregates: inout [String: DailyAggregate], pricing: PricingTable) {
        for dayKey in Array(aggregates.keys) {
            guard var day = aggregates.removeValue(forKey: dayKey) else { continue }
            for modelKey in Array(day.perModel.keys) {
                guard var model = day.perModel.removeValue(forKey: modelKey) else { continue }
                if model.model == ModelNormalizer.syntheticFamily {
                    model.cost = 0
                    model.surchargeUSD = 0
                } else if !model.pricingUsage.isEmpty {
                    let costs = pricingCosts(for: model.pricingUsage, pricing: pricing)
                    model.cost = costs.total
                    model.surchargeUSD = costs.surcharge
                } else {
                    model.cost = legacyBaseCost(for: model, pricing: pricing) + model.surchargeUSD
                }
                day.perModel[modelKey] = model
            }
            for projectKey in Array(day.perProject.keys) {
                guard var project = day.perProject.removeValue(forKey: projectKey) else { continue }
                if !project.pricingUsage.isEmpty {
                    let costs = pricingCosts(for: project.pricingUsage, pricing: pricing)
                    project.cost = costs.total
                    let hasSyntheticUsage = project.perModel[ModelNormalizer.syntheticFamily] != nil
                    project.perModel = costs.perFamily
                    if hasSyntheticUsage { project.perModel[ModelNormalizer.syntheticFamily] = 0 }
                }
                day.perProject[projectKey] = project
            }
            aggregates[dayKey] = day
        }
    }

    /// Reprice complete retained groups for either a model or a project.
    /// The summed token counts use the key's original prompt length, not their cumulative length.
    private static func pricingCosts(for usage: [PricingUsageKey: TokenUsage], pricing: PricingTable)
        -> (total: Double, surcharge: Double, perFamily: [String: Double]) {
        var total = 0.0
        var surcharge = 0.0
        var perFamily: [String: Double] = [:]
        for (key, tokens) in usage {
            let base = pricing.cost(of: tokens, family: key.family, rawModel: key.rawModel,
                                    promptTokens: key.promptTokens, rateDayUTC: key.rateDayUTC)
            let multiplier = pricing.surchargeMultiplier(
                family: key.family, rawModel: key.rawModel, isFast: key.isFast,
                isDomestic: key.isDomestic, rateDayUTC: key.rateDayUTC)
            let cost = base * multiplier
            total += cost
            surcharge += base * (multiplier - 1)
            perFamily[key.family, default: 0] += cost
        }
        return (total, surcharge, perFamily)
    }

    /// Legacy snapshots lack dates and flags. Prefer raw-model and original-prompt slices;
    /// price any unbucketed remainder at short-context rates rather than guessing request tiers.
    private static func legacyBaseCost(for model: ModelUsage, pricing: PricingTable) -> Double {
        if model.perRawModelUsage.isEmpty {
            return pricing.cost(of: model.usage, family: model.model,
                                rawModel: model.rawModel, promptTokens: 0)
        }
        return model.perRawModelUsage.reduce(0) { sum, entry in
            if let promptUsage = model.perRawModelPromptUsage[entry.key] {
                let bucketCost = promptUsage.reduce(0) { promptSum, bucket in
                    promptSum + pricing.cost(of: bucket.value, family: model.model,
                                             rawModel: entry.key, promptTokens: bucket.key)
                }
                let bucketUsage = promptUsage.values.reduce(TokenUsage(), +)
                let remainder = TokenUsage(
                    input: max(0, entry.value.input - bucketUsage.input),
                    output: max(0, entry.value.output - bucketUsage.output),
                    cacheRead: max(0, entry.value.cacheRead - bucketUsage.cacheRead),
                    cacheWrite5m: max(0, entry.value.cacheWrite5m - bucketUsage.cacheWrite5m),
                    cacheWrite1h: max(0, entry.value.cacheWrite1h - bucketUsage.cacheWrite1h),
                    webSearchRequests: max(0, entry.value.webSearchRequests - bucketUsage.webSearchRequests))
                return sum + bucketCost + pricing.cost(of: remainder, family: model.model,
                                                      rawModel: entry.key, promptTokens: 0)
            }
            return sum + pricing.cost(of: entry.value, family: model.model,
                                      rawModel: entry.key, promptTokens: 0)
        }
    }

    /// Drop aggregates older than the retention cutoff day (inclusive lower bound).
    static func prune(_ aggregates: inout [String: DailyAggregate], onOrAfter cutoffDay: String) {
        aggregates = aggregates.filter { $0.key >= cutoffDay }
    }
}
