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
        /// The pricing table version used when the aggregates were last costed; 0 means unknown.
        /// `lastCostedPricing` and `needsRecost` also detect changes within the same version.
        var pricingVersion: Int = 0
        /// Tracks data-model migrations that require a full re-scan.
        /// 0 = pre-project-tracking; 1 = perProject populated from scan;
        /// 2 = taxableCacheRead (context-tax tokens) populated from scan;
        /// 3 = repair re-fold for clients stuck at v2 with empty taxableCacheRead.
        var dataVersion: Int = 0
        var todayConcurrency: ConcurrencyStats = ConcurrencyStats()

        /// The user's launch-at-login *intent*, as opposed to the current system state.
        /// `SMAppService` registers the running bundle, so its answer is lost whenever the
        /// app changes location. Recording what the user asked for lets us restore it.
        var launchAtLogin: Bool = false
        /// Where the app was running from at last launch. A change means the bundle moved,
        /// which is one of the cases where a lost login-item registration is an accident
        /// rather than the user's choice. Empty on the first launch that tracks it.
        var lastBundlePath: String = ""
        /// The version that ran last. An in-place update replaces the bundle without
        /// changing its path, so this is the only signal that distinguishes "the bundle
        /// was swapped underneath the registration" from "the user switched it off".
        var lastVersion: String = ""
        /// The pricing table that the aggregates were last costed with. Comparing it with the
        /// loaded table detects a same-version edit to pricing.json, which `pricingVersion` cannot.
        /// nil means the snapshot predates this field, so the table is unknown.
        var lastCostedPricing: PricingTable? = nil

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
            launchAtLogin      = (try? c.decode(Bool.self,              forKey: .launchAtLogin))      ?? false
            lastBundlePath     = (try? c.decode(String.self,            forKey: .lastBundlePath))     ?? ""
            lastVersion        = (try? c.decode(String.self,            forKey: .lastVersion))        ?? ""
            lastCostedPricing  = try? c.decode(PricingTable.self,      forKey: .lastCostedPricing)
        }
        private enum CodingKeys: String, CodingKey {
            case scanState, aggregates, settings, lastAlertDay, lastTipDay, pricingVersion, dataVersion, todayConcurrency
            case launchAtLogin, lastBundlePath, lastVersion, lastCostedPricing
        }

        /// True when the aggregates must be costed again with `pricing`.
        /// A higher version always triggers it. A missing `lastCostedPricing` also triggers it, because
        /// the snapshot cannot prove that its cached totals match the current rates, even at the same version.
        /// A recorded table triggers it whenever its content differs, including at a lower version.
        func needsRecost(pricing: PricingTable) -> Bool {
            if pricingVersion < (pricing.version ?? 0) { return true }
            guard let costed = lastCostedPricing else { return true }
            return costed != pricing
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
    ///   v4: cost-calculation fold logic changed (incremental per-record costing + surchargeUSD,
    ///       Bedrock/provider-prefix exact-key pricing, new model-version overrides). Aggregates
    ///       computed under the old fold are stale and understate/overstate cost; re-fold to repair.
    ///   v6: rebuild Sol costs with routed cache rates, original prompt lengths, UTC rate days,
    ///       project billable buckets and surcharge flags. Daily sums cannot recover these inputs.
    static let currentDataVersion = 6

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

    /// Loads the user's pricing.json, seeding it from the bundled table on first run.
    ///
    /// When the bundled `version` is higher, the installed table is merged with the bundled one
    /// (see `mergeUpgrade`). The installed bytes are backed up first, and the baseline moves only
    /// after the new file is written. An unreadable installed file is never overwritten.
    /// Bump `PricingTable.default.version` (and the `version` field in Resources/pricing.json)
    /// whenever rates change.
    static func loadPricing(in directory: URL = supportDirectory, bundled suppliedBundled: PricingTable? = nil) -> PricingTable {
        let pricingFile = directory.appendingPathComponent("pricing.json")
        let bundledBytes = suppliedBundled == nil ? bundledResourceData() : nil
        let bundled = suppliedBundled
            ?? bundledBytes.flatMap { try? JSONDecoder().decode(PricingTable.self, from: $0) }
            ?? PricingTable.default

        guard FileManager.default.fileExists(atPath: pricingFile.path) else {
            return seedPricing(bundled: bundled, bundledBytes: bundledBytes, in: directory)
        }
        guard let installedBytes = try? Data(contentsOf: pricingFile),
              let installed = try? JSONDecoder().decode(PricingTable.self, from: installedBytes) else {
            AppLog.shared.error("pricing.json exists but cannot be read or decoded; " +
                                "left it unchanged and using the bundled table in memory", category: "pricing")
            return bundled
        }

        let installedVersion = installed.version ?? 0
        let bundledVersion = bundled.version ?? 0
        let baseline = readBaseline(in: directory)

        if bundledVersion > installedVersion {
            let merged = mergeUpgrade(installed: installed, bundled: bundled, baseline: baseline)
            guard let backup = writeBackup(installedBytes, beside: pricingFile) else {
                AppLog.shared.error("could not back up pricing.json; left it unchanged and using the upgraded table in memory", category: "pricing")
                return merged
            }
            guard let data = try? JSONEncoder().encode(merged), (try? data.write(to: pricingFile, options: .atomic)) != nil else {
                AppLog.shared.error("could not write the upgraded pricing.json; the file is unchanged " +
                                    "(backup at \(backup.lastPathComponent)) and the upgraded table is used in memory",
                                    category: "pricing")
                return merged
            }
            // A baseline newer than the bundled table is never replaced by an older one.
            if (baseline?.version ?? 0) <= bundledVersion, !writeBaseline(bundled, in: directory) {
                AppLog.shared.error("upgraded pricing.json but could not record the baseline; " +
                                    "the next upgrade keeps these rates as user-owned", category: "pricing")
            }
            AppLog.shared.info("pricing upgraded from v\(installedVersion) to v\(bundledVersion); " +
                               "previous file backed up as \(backup.lastPathComponent)", category: "pricing")
            return merged
        }

        if bundledVersion == installedVersion, baseline == nil, installed == bundled {
            if !writeBaseline(bundled, in: directory) {
                AppLog.shared.error("could not record the pricing baseline; pricing.json is unchanged", category: "pricing")
            }
        }
        if installedVersion > bundledVersion {
            AppLog.shared.info("pricing loaded v\(installedVersion), newer than bundled v\(bundledVersion); kept the installed table", category: "pricing")
        } else {
            AppLog.shared.info("pricing loaded v\(installedVersion)", category: "pricing")
        }
        return installed
    }

    /// Sidecar file that holds the bundled table of the last upgrade. It is the reference for
    /// telling unedited defaults from user edits. Only the app writes it.
    static func baselineURL(in directory: URL) -> URL {
        directory.appendingPathComponent("pricing-defaults.json")
    }

    /// Bundled pricing.json bytes. Use Bundle.main.url(forResource:subdirectory:) so the lookup works
    /// from Contents/Resources/ where build_app.sh places the bundle (codesign requires resources
    /// inside Contents/, not at the .app root where Bundle.module would look).
    private static func bundledResourceData() -> Data? {
        let url = Bundle.main.url(forResource: "pricing", withExtension: "json",
                                  subdirectory: "ClaudeOMeter_ClaudeOMeter.bundle")
            ?? Bundle.module.url(forResource: "pricing", withExtension: "json")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    /// First run: write the bundled table as the editable copy and as the baseline.
    /// The bundled bytes are written as-is only when they decode, so the seeded file keeps the bundled formatting.
    /// Otherwise the table in use (the Swift fallback) is encoded instead.
    static func seedPricing(bundled: PricingTable, bundledBytes: Data?, in directory: URL) -> PricingTable {
        let pricingFile = directory.appendingPathComponent("pricing.json")
        let validBundledBytes = bundledBytes.flatMap { data in
            (try? JSONDecoder().decode(PricingTable.self, from: data)) == nil ? nil : data
        }
        guard let seed = validBundledBytes ?? (try? JSONEncoder().encode(bundled)),
              (try? seed.write(to: pricingFile, options: .atomic)) != nil else {
            AppLog.shared.error("could not seed pricing.json; using the bundled table in memory", category: "pricing")
            return bundled
        }
        if !writeBaseline(bundled, in: directory) {
            AppLog.shared.error("seeded pricing.json but could not record the baseline; the next upgrade keeps all rates as user-owned", category: "pricing")
        }
        AppLog.shared.info("seeded pricing.json from bundled v\(bundled.version ?? 0)", category: "pricing")
        return bundled
    }

    /// The baseline, or nil when the file is absent or does not decode. Nil means "unknown",
    /// and an upgrade then keeps every installed rate.
    static func readBaseline(in directory: URL) -> PricingTable? {
        guard let data = try? Data(contentsOf: baselineURL(in: directory)) else { return nil }
        return try? JSONDecoder().decode(PricingTable.self, from: data)
    }

    /// Writes the baseline atomically. Returns false on any I/O or encoding error.
    @discardableResult
    static func writeBaseline(_ table: PricingTable, in directory: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(table) else { return false }
        return (try? data.write(to: baselineURL(in: directory), options: .atomic)) != nil
    }

    /// Copies the installed bytes to a new file beside pricing.json, named with a UTC timestamp.
    /// An existing backup is never overwritten; a numeric suffix is added instead.
    static func writeBackup(_ bytes: Data, beside pricingFile: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let directory = pricingFile.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("pricing.json.backup-\(stamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("pricing.json.backup-\(stamp)-\(suffix)")
            suffix += 1
        }
        do {
            try bytes.write(to: candidate, options: .withoutOverwriting)
            return candidate
        } catch {
            return nil
        }
    }

    /// The table written when the bundled version is newer than the installed one.
    /// The installed table is the base, so its discount, its user-only fields and its extra entries stay.
    /// Each default value changes only when the baseline shows that the user never edited it.
    /// With no baseline, nothing is replaced and only missing keys are added.
    static func mergeUpgrade(installed: PricingTable, bundled: PricingTable, baseline: PricingTable?) -> PricingTable {
        var merged = installed
        merged.version = max(installed.version ?? 0, bundled.version ?? 0)
        merged.models = mergeEntries(installed.models, bundled: bundled.models, baseline: baseline?.models)
        let history = mergeHistory(installed: installed, bundled: bundled, baseline: baseline, mergedModels: merged.models)
        merged.modelPriceHistory = history.isEmpty ? nil : history
        merged.fallback = mergeField(installed.fallback, bundled.fallback,
                                     baseline: baseline?.fallback, baselineKnown: baseline != nil)
        merged.webSearchCost = mergeField(installed.webSearchCost, bundled.webSearchCost,
                                          baseline: baseline?.webSearchCost, baselineKnown: baseline != nil)
        merged.usOnlyMultiplier = mergeField(installed.usOnlyMultiplier, bundled.usOnlyMultiplier,
                                             baseline: baseline?.usOnlyMultiplier, baselineKnown: baseline != nil)
        return merged
    }

    /// Merges the dated price history per model. Two cases take a bundled revision list.
    /// A model that the merge adds with its bundled base price has no user data, so it takes the bundled history.
    /// A model that the installed table already has takes it only when the baseline is known, the merged base
    /// price is the bundled one, and the installed list matches the baseline list.
    /// So a user rate, or a list the user edited or deleted, is never overridden by a new dated revision.
    /// Keys with no model in `mergedModels` are skipped, so the result always decodes.
    static func mergeHistory(installed: PricingTable, bundled: PricingTable, baseline: PricingTable?,
                             mergedModels: [String: ModelPrice]) -> [String: [DatedModelPrice]] {
        var history = installed.modelPriceHistory ?? [:]
        for (key, revisions) in bundled.modelPriceHistory ?? [:] {
            guard let mergedBase = mergedModels[key], mergedBase == bundled.models[key] else { continue }
            if installed.models[key] == nil {
                history[key] = revisions
                continue
            }
            guard let baseline = baseline else { continue }
            guard installed.modelPriceHistory?[key] == baseline.modelPriceHistory?[key] else { continue }
            history[key] = revisions
        }
        return history
    }

    /// Merges one keyed map, such as the model rates.
    /// 1. A key that the installed map lacks is added only when the baseline did not have it.
    ///    A key the baseline had is a deletion by the user, so it is not added again.
    /// 2. A key that both maps have is replaced only when the baseline has the same value as the installed map.
    /// 3. Keys that the bundled map does not have are kept.
    static func mergeEntries<V: Equatable>(_ installed: [String: V], bundled: [String: V], baseline: [String: V]?) -> [String: V] {
        var merged = installed
        for (key, newValue) in bundled {
            guard let current = installed[key] else {
                if baseline?[key] == nil { merged[key] = newValue }
                continue
            }
            if let base = baseline?[key], base == current {
                merged[key] = newValue
            }
        }
        return merged
    }

    /// Merges one optional field with the same rules as `mergeEntries`.
    /// With an unknown baseline, the installed value wins, and the bundled value fills an absent field.
    static func mergeField<T: Equatable>(_ installed: T?, _ bundled: T?, baseline: T?, baselineKnown: Bool) -> T? {
        guard baselineKnown else { return installed ?? bundled }
        guard let current = installed else { return baseline == nil ? bundled : nil }
        if let base = baseline, base == current, let newValue = bundled { return newValue }
        return current
    }
}
