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
        let ctx = u.input + u.cacheWrite5m + u.cacheWrite1h + u.cacheRead
        guard ctx > healthyContextCap else { return 0 }
        let over = Double(ctx - healthyContextCap) / Double(ctx)
        return Int((Double(u.cacheRead) * over).rounded())
    }

    /// Fold new records into `aggregates`, recomputing per-model cost with `pricing`.
    static func fold(
        records: [UsageRecord],
        into aggregates: inout [String: DailyAggregate],
        pricing: PricingTable
    ) {
        for rec in records {
            var day = aggregates[rec.day] ?? DailyAggregate(day: rec.day)
            var model = day.perModel[rec.model] ?? ModelUsage(model: rec.model, rawModel: rec.rawModel)
            let prevCost = model.cost
            model.usage = model.usage + rec.usage
            model.rawModel = rec.rawModel   // always use the latest rawModel seen for this family/day
            model.cost = pricing.cost(of: model.usage, family: rec.model, rawModel: rec.rawModel)
            day.perModel[rec.model] = model

            let taxable = taxableCacheRead(for: rec)
            if taxable > 0 { day.taxableCacheRead[rec.model, default: 0] += taxable }

            if !rec.projectDir.isEmpty {
                let delta = model.cost - prevCost
                var pu = day.perProject[rec.projectDir] ?? ProjectUsage()
                pu.cost += delta
                pu.perModel[rec.model, default: 0] += delta
                if taxable > 0 { pu.taxableCacheRead[rec.model, default: 0] += taxable }
                day.perProject[rec.projectDir] = pu
            }
            aggregates[rec.day] = day
        }
    }

    /// Recompute all costs (used when pricing.json changes).
    static func recost(_ aggregates: inout [String: DailyAggregate], pricing: PricingTable) {
        for (day, agg) in aggregates {
            var newAgg = agg
            for (key, var model) in agg.perModel {
                model.cost = pricing.cost(of: model.usage, family: model.model, rawModel: model.rawModel)
                newAgg.perModel[key] = model
            }
            aggregates[day] = newAgg
        }
    }

    /// Drop aggregates older than the retention cutoff day (inclusive lower bound).
    static func prune(_ aggregates: inout [String: DailyAggregate], onOrAfter cutoffDay: String) {
        aggregates = aggregates.filter { $0.key >= cutoffDay }
    }
}
