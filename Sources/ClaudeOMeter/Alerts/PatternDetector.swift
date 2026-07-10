import Foundation

struct PatternInsight: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case good, bad }
    let id: String
    let kind: Kind
    let title: String
    let detail: String

    // Minimum days between notifications for each bad-pattern tip.
    static let notificationCadence: [String: Int] = [
        "opus_heavy":     7,
        "cache_miss":     30,
        "spend_spike":    7,
        "context_bloat":  7,
        "burnrate":       7,
        "claudemd_bloat": 30,
    ]
}

/// Pure pattern-detection logic over the persisted daily aggregates.
enum PatternDetector {

    // MARK: - Detection

    static func detect(
        aggregates: [String: DailyAggregate],
        settings: AlertSettings = AlertSettings(),
        concurrency: ConcurrencyStats = ConcurrencyStats(),
        pricing: PricingTable = .default,
        now: Date = Date()
    ) -> [PatternInsight] {
        var insights: [PatternInsight] = []

        if let parallelInsight = detectParallelism(stats: concurrency) {
            insights.append(parallelInsight)
        }

        let last7  = window(aggregates, from: 1, count: 7, now: now)
        let prior7 = window(aggregates, from: 8, count: 7, now: now)

        let last7Cost = last7.reduce(0.0) { $0 + $1.totalCost }
        guard last7Cost >= 0.50 else { return insights }

        // --- Cache efficiency ---
        let allUsage = last7.flatMap { $0.perModel.values.map { $0.usage } }
        let totalInput     = allUsage.reduce(0) { $0 + $1.input }
        let totalCacheRead = allUsage.reduce(0) { $0 + $1.cacheRead }
        let cacheable = totalInput + totalCacheRead

        if cacheable > 50_000 {
            let hitRate = Double(totalCacheRead) / Double(cacheable)
            if hitRate < 0.15 {
                insights.append(PatternInsight(
                    id: "cache_miss", kind: .bad,
                    title: "Low cache hit rate (\(Int(hitRate * 100))%)",
                    detail: "Add a CLAUDE.md in your project root — it primes the cache on every session start, making subsequent turns up to 10× cheaper."
                ))
            } else if hitRate >= 0.50 {
                insights.append(PatternInsight(
                    id: "cache_high", kind: .good,
                    title: "Cache efficiency at \(Int(hitRate * 100))%",
                    detail: "Cached tokens cost ~10× less than fresh input — your workflow is well optimised."
                ))
            }
        }

        // --- Model selection ---
        let opusCost = last7.reduce(0.0) { $0 + ($1.perModel["opus"]?.cost ?? 0) }
        if last7Cost >= 1.0 {
            let opusFraction = opusCost / last7Cost
            if opusFraction > 0.60 {
                insights.append(PatternInsight(
                    id: "opus_heavy", kind: .bad,
                    title: "Opus is \(Int(opusFraction * 100))% of 7-day spend",
                    detail: "For everyday coding, Sonnet delivers comparable results at ~6× lower cost. Run `/model sonnet` to switch."
                ))
            } else if opusFraction < 0.40 && last7Cost >= 2.0 {
                insights.append(PatternInsight(
                    id: "model_efficient", kind: .good,
                    title: "Good model selection",
                    detail: "Using lighter models for routine tasks is keeping your costs down efficiently."
                ))
            }
        }

        // --- Spend trend ---
        let prior7Cost = prior7.reduce(0.0) { $0 + $1.totalCost }
        let prior7Avg  = prior7Cost / 7.0
        let last7Avg   = last7Cost / 7.0

        if prior7Avg >= 0.10 {
            if last7Avg >= prior7Avg * 1.60 {
                let pct = Int(((last7Avg / prior7Avg - 1) * 100).rounded())
                insights.append(PatternInsight(
                    id: "spend_spike", kind: .bad,
                    title: "Spending up \(pct)% vs last week",
                    detail: "Daily average rose from \(Fmt.usd(prior7Avg)) to \(Fmt.usd(last7Avg)). Review model selection or prompt patterns."
                ))
            } else if last7Avg <= prior7Avg * 0.70 {
                let pct = Int(((1 - last7Avg / prior7Avg) * 100).rounded())
                insights.append(PatternInsight(
                    id: "spend_down", kind: .good,
                    title: "Spending down \(pct)% vs last week",
                    detail: "Daily average dropped from \(Fmt.usd(prior7Avg)) to \(Fmt.usd(last7Avg)) — great efficiency improvement."
                ))
            }
        }

        // --- Context bloat: recoverable dollars from cache-read re-read above the healthy cap ---
        // Priced from stored taxable tokens so it tracks current pricing.json. Shown only when the
        // recoverable amount is both materially large ($5+) and a meaningful slice of spend (5%+),
        // so disciplined-but-heavy users aren't nagged.
        // Price per day-family using the day's actual rawModel so exact per-version rates
        // (e.g. claude-opus-4-1 reads cost 3× the family fallback) aren't undercounted.
        var contextTax = 0.0
        for agg in last7 {
            for (fam, tokens) in agg.taxableCacheRead {
                let rawModel = agg.perModel[fam]?.rawModel ?? fam
                contextTax += pricing.cost(of: TokenUsage(cacheRead: tokens), family: fam, rawModel: rawModel)
            }
        }
        if contextTax >= 5.0, contextTax >= last7Cost * 0.05 {
            let capK = Aggregator.healthyContextCap / 1000
            var detail = "Over the last 7 days you paid ~\(Fmt.usd(contextTax)) in avoidable cache reads — re-reading context above a healthy ~\(capK)K working size."
            if let top = topContextTaxProject(last7, pricing: pricing) {
                detail += " Most of it is in \(top)."
            }
            detail += " Run /compact before sessions balloon, or /clear between tasks."
            insights.append(PatternInsight(
                id: "context_bloat", kind: .bad,
                title: "~\(Fmt.usd(contextTax)) recoverable from context bloat",
                detail: detail
            ))
        }

        // --- Month-end burn rate projection ---
        let todayStr = DayBucket.localDay(from: now)
        let todayParts = todayStr.split(separator: "-")
        if todayParts.count == 3, let dayOfMonth = Int(todayParts[2]), dayOfMonth >= 3 {
            let monthPrefix = "\(todayParts[0])-\(todayParts[1])"
            let monthToDate = aggregates.values
                .filter { $0.day.hasPrefix(monthPrefix) }
                .reduce(0.0) { $0 + $1.totalCost }

            let daysInMonth   = Calendar.current.range(of: .day, in: .month, for: now)?.count ?? 30
            let daysRemaining = max(0, daysInMonth - dayOfMonth)
            // Use completed days only — today's partial spend would understate the daily average.
            // completedDays >= 2 because dayOfMonth >= 3.
            let completedDays = dayOfMonth - 1
            let todayInMonthCost = aggregates[todayStr]?.totalCost ?? 0
            let avgDaily = (monthToDate - todayInMonthCost) / Double(completedDays)
            let projected = monthToDate + Double(daysRemaining) * avgDaily

            if avgDaily >= 0.20 && projected >= 10.0 {
                let detail: String
                if let limit = settings.monthlyThreshold {
                    let pct = Int((projected / limit) * 100)
                    detail = "At \(Fmt.usd(avgDaily))/day avg, you're on pace for \(pct)% of your \(Fmt.usd(limit)) monthly budget."
                } else {
                    detail = "At \(Fmt.usd(avgDaily))/day avg. Set a monthly budget in Settings to get an alert when you're close."
                }
                insights.append(PatternInsight(
                    id: "burnrate", kind: .bad,
                    title: "On pace for ~\(Fmt.usd(projected)) this month",
                    detail: detail
                ))
            }
        }

        // --- Global CLAUDE.md length (including @-imported files) ---
        if let (lineCount, hasImports) = claudeMdTotalLines(), lineCount > 200 {
            let subject = hasImports ? "Global CLAUDE.md + imports" : "Global CLAUDE.md"
            insights.append(PatternInsight(
                id: "claudemd_bloat", kind: .bad,
                title: "\(subject) has \(lineCount) lines",
                detail: "Your global CLAUDE.md loads on every API call across all projects. Trim to under 200 lines by removing rules Claude can infer from code."
            ))
        }

        return insights
    }

    // MARK: - Notification scheduling

    /// Returns the IDs of bad tips that should fire a notification today.
    static func tipsToNotify(
        insights: [PatternInsight],
        lastTipDay: [String: String],
        today: String,
        now: Date = Date()
    ) -> [String] {
        insights
            .filter { $0.kind == .bad }
            .compactMap { insight -> String? in
                guard let cadence = PatternInsight.notificationCadence[insight.id] else {
                    AppLog.shared.warning("insight '\(insight.id)' has no notification cadence — suppressed", category: "alerts")
                    return nil
                }
                guard let lastStr = lastTipDay[insight.id] else { return insight.id }
                return daysSince(lastStr, now: now) >= cadence ? insight.id : nil
            }
    }

    // MARK: - Private helpers

    private static func detectParallelism(stats: ConcurrencyStats) -> PatternInsight? {
        guard stats.peakUserSessions >= 2 else { return nil }

        let title: String
        let detail: String
        let peak = stats.peakUserSessions
        let agents = stats.peakSubagents

        if agents >= 3 && peak >= 3 {
            title = "\(peak) projects in flight at once · \(agents) agents running concurrently"
            let projects = stats.peakProjectNames.prefix(3).joined(separator: ", ")
            detail = "At peak you had \(peak) sessions (\(projects)) and \(agents) subagents active simultaneously — the throughput of a small team compressed into one developer."
        } else if agents >= 3 {
            title = "\(peak) projects active · \(agents) agents working in parallel"
            detail = "You orchestrated \(agents) parallel subagents today — that's AI doing the coordination work so you don't have to."
        } else if peak >= 3 {
            let projects = stats.peakProjectNames.prefix(3).joined(separator: ", ")
            title = "\(peak) projects in flight at once today"
            detail = "You ran \(projects) simultaneously — parallel sessions are where individual developers start working like teams."
        } else {
            let projects = stats.peakProjectNames.prefix(2).joined(separator: " and ")
            title = "Running \(projects.isEmpty ? "2 projects" : projects) in parallel today"
            detail = "Parallel sessions multiply your throughput — you're advancing multiple workstreams at once instead of sequentially."
        }

        return PatternInsight(id: "parallelism", kind: .good, title: title, detail: detail)
    }

    private static func window(_ aggs: [String: DailyAggregate], from start: Int, count: Int, now: Date = Date()) -> [DailyAggregate] {
        (start..<(start + count)).compactMap { aggs[DayBucket.day(daysAgo: $0, from: now)] }
    }

    /// The project carrying the most priced context tax across the given days, as a display name.
    /// Returns nil if no project has any taxable cache-read.
    private static func topContextTaxProject(_ aggs: [DailyAggregate], pricing: PricingTable) -> String? {
        var taxByDir: [String: Double] = [:]
        for agg in aggs {
            for (dir, usage) in agg.perProject {
                for (fam, tokens) in usage.taxableCacheRead {
                    let rawModel = agg.perModel[fam]?.rawModel ?? fam
                    taxByDir[dir, default: 0] += pricing.cost(
                        of: TokenUsage(cacheRead: tokens), family: fam, rawModel: rawModel
                    )
                }
            }
        }
        guard let topDir = taxByDir.max(by: { $0.value < $1.value })?.key else { return nil }
        return TranscriptScanner.projectDisplayName(from: topDir)
    }

    /// Count lines in ~/.claude/CLAUDE.md plus any @-imported files (Claude Code import syntax).
    /// Returns nil if the file doesn't exist.
    private static func claudeMdTotalLines() -> (count: Int, hasImports: Bool)? {
        let rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md")
        guard let content = try? String(contentsOf: rootURL, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        var total = lines.count
        var importCount = 0
        var seen: Set<String> = [rootURL.path]
        let dir = rootURL.deletingLastPathComponent()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@") else { continue }
            let ref = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty else { continue }

            let resolved: URL
            if ref.hasPrefix("/") {
                resolved = URL(fileURLWithPath: ref)
            } else if ref.hasPrefix("~") {
                resolved = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
            } else {
                resolved = dir.appendingPathComponent(ref)
            }

            guard !seen.contains(resolved.path) else { continue }
            seen.insert(resolved.path)
            if let imported = try? String(contentsOf: resolved, encoding: .utf8) {
                total += imported.components(separatedBy: .newlines).count
                importCount += 1
            }
        }

        return (total, importCount > 0)
    }

    private static func daysSince(_ dayString: String, now: Date = Date()) -> Int {
        guard let past = DayBucket.date(fromDay: dayString) else { return Int.max }
        return Calendar.current.dateComponents([.day], from: past, to: now).day ?? Int.max
    }
}
