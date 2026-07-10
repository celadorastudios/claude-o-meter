import Foundation

/// On-disk locations under Application Support, plus the persisted snapshot shape.
enum Persistence {
    /// Days the history list / chart shows.
    static let displayDays = 30
    /// Days of aggregates retained on disk. One more than `displayDays` so month-to-date
    /// stays accurate on the last day of a 31-day month.
    static let retentionDays = 31
    /// Keep seen-ids a bit longer than the retention window to keep dedup stable near the edge.
    static let seenIDBufferDays = 7

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ClaudeOMeter", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.error("failed to create support directory: \(error)", category: "persistence")
        }
        return dir
    }()

    static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    static var pricingURL: URL { supportDirectory.appendingPathComponent("pricing.json") }

    /// Everything we persist between launches.
    struct Snapshot: Codable, Sendable {
        var scanState: ScanState = ScanState()
        var aggregates: [String: DailyAggregate] = [:]   // day -> aggregate
        var settings: AlertSettings = AlertSettings()
        var lastAlertDay: [String: String] = [:]         // alert key -> day last fired
        var lastTipDay: [String: String] = [:]           // tip id -> day last notified
        /// The pricing table version used when the aggregates were last costed.
        /// 0 means unknown (pre-versioning). When this is less than the loaded
        /// pricing version, UsageStore.init() calls Aggregator.recost() to
        /// reapply current rates before the first display pass.
        var pricingVersion: Int = 0
        /// Tracks data-model migrations that require a full re-scan.
        /// 0 = pre-project-tracking; 1 = perProject populated from scan;
        /// 2 = taxableCacheRead (context-tax tokens) populated from scan;
        /// 3 = repair re-fold for clients stuck at v2 with empty taxableCacheRead.
        var dataVersion: Int = 0
        var todayConcurrency: ConcurrencyStats = ConcurrencyStats()

        init() {}

        // Defensive decoder: each field falls back to its default on missing key or type
        // mismatch. This means schema additions to any nested struct (e.g. new fields in
        // AlertSettings, ModelUsage, TokenUsage) never cause the entire snapshot decode to
        // fail and silently wipe user settings.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scanState      = (try? c.decode(ScanState.self,                   forKey: .scanState))      ?? ScanState()
            aggregates     = (try? c.decode([String: DailyAggregate].self,    forKey: .aggregates))     ?? [:]
            settings       = (try? c.decode(AlertSettings.self,               forKey: .settings))       ?? AlertSettings()
            lastAlertDay   = (try? c.decode([String: String].self,            forKey: .lastAlertDay))   ?? [:]
            lastTipDay     = (try? c.decode([String: String].self,            forKey: .lastTipDay))     ?? [:]
            pricingVersion     = (try? c.decode(Int.self,               forKey: .pricingVersion))     ?? 0
            dataVersion        = (try? c.decode(Int.self,               forKey: .dataVersion))        ?? 0
            todayConcurrency   = (try? c.decode(ConcurrencyStats.self,  forKey: .todayConcurrency))   ?? ConcurrencyStats()
        }
        private enum CodingKeys: String, CodingKey {
            case scanState, aggregates, settings, lastAlertDay, lastTipDay, pricingVersion, dataVersion, todayConcurrency
        }
    }

    static func loadSnapshot() -> Snapshot {
        guard let data = try? Data(contentsOf: stateURL) else { return Snapshot() }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            AppLog.shared.error("state.json decode failed (schema change or corruption?): \(error)", category: "persistence")
            return Snapshot()
        }
    }

    static func save(_ snapshot: Snapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            AppLog.shared.error("failed to save state: \(error)", category: "persistence")
        }
    }

    /// Current on-disk data-model version. Bump whenever the fold gains a field that can only
    /// be computed at fold time (fold-time fields can't be backfilled from summed aggregates,
    /// and deduped message IDs are never re-folded otherwise).
    ///   v1: perProject tracking.
    ///   v2: taxableCacheRead (context-tax tokens) — added for the context_bloat insight.
    ///   v3: repair re-fold for clients stuck at v2 — a build that stamped dataVersion 2 before
    ///       the taxable fold was correct leaves taxableCacheRead permanently empty (the one-shot
    ///       v2 guard never re-fires), so context_bloat can never surface. Re-fold to backfill.
    static let currentDataVersion = 3

    /// Pure migration to `currentDataVersion`. When the stored version is older, scanState and
    /// aggregates are cleared so the next scan re-folds every JSONL file; settings and alert/tip
    /// state are preserved. Returns a new snapshot (never mutates the input) and whether a
    /// migration occurred so the caller can persist and log only when something changed.
    static func migrate(_ snapshot: Snapshot) -> (snapshot: Snapshot, didMigrate: Bool) {
        guard snapshot.dataVersion < currentDataVersion else { return (snapshot, false) }
        var migrated = snapshot
        migrated.scanState = ScanState()
        migrated.aggregates = [:]
        migrated.dataVersion = currentDataVersion
        return (migrated, true)
    }

    /// Load user pricing.json, seeding or auto-upgrading from the bundled copy when needed.
    ///
    /// Auto-upgrade: if the bundled `version` field is higher than the installed one, the
    /// installed file is replaced with the bundled rates — preserving `discountPercent` so
    /// enterprise users don't lose their discount. Bump `PricingTable.default.version` (and
    /// the `version` field in Resources/pricing.json) whenever rates change.
    static func loadPricing() -> PricingTable {
        // Use Bundle.main.url(forResource:subdirectory:) so the lookup works from
        // Contents/Resources/ where the bundle is placed by build_app.sh (codesign requires
        // resources inside Contents/, not at the .app root where Bundle.module would look).
        let bundledURL = Bundle.main.url(forResource: "pricing", withExtension: "json",
                                         subdirectory: "ClaudeOMeter_ClaudeOMeter.bundle")
                      ?? Bundle.module.url(forResource: "pricing", withExtension: "json")

        let bundledData = bundledURL.flatMap { try? Data(contentsOf: $0) }
        let bundled = bundledData.flatMap { try? JSONDecoder().decode(PricingTable.self, from: $0) }
            ?? PricingTable.default

        let installedData = try? Data(contentsOf: pricingURL)
        let installed = installedData.flatMap { try? JSONDecoder().decode(PricingTable.self, from: $0) }

        if installed == nil {
            // First run: seed editable copy from bundled.
            if let data = bundledData ?? (try? JSONEncoder().encode(PricingTable.default)) {
                try? data.write(to: pricingURL, options: .atomic)
            }
            return bundled
        }

        // Auto-upgrade: bundled version is newer → replace rates, keep user's discount.
        if (bundled.version ?? 0) > (installed!.version ?? 0) {
            AppLog.shared.info("pricing auto-upgraded from v\(installed!.version ?? 0) to v\(bundled.version ?? 0)", category: "pricing")
            var upgraded = bundled
            upgraded.discountPercent = installed!.discountPercent
            if let data = try? JSONEncoder().encode(upgraded) {
                try? data.write(to: pricingURL, options: .atomic)
            }
            return upgraded
        }

        AppLog.shared.info("pricing loaded v\(installed!.version ?? 0)", category: "pricing")
        return installed!
    }
}
