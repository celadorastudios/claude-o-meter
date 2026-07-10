import Foundation
import Combine

/// Central observable state for the menu bar UI. Owns persistence, scanning, aggregation, alerts.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var days: [DailyAggregate] = []     // most-recent first, within retention
    @Published private(set) var tips: [PatternInsight] = []
    @Published private(set) var projectTotals: [(dir: String, name: String, cost: Double)] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    enum UpdateCheckOutcome: Equatable {
        case upToDate
        case available(String)  // version string
    }

    @Published private(set) var availableUpdate: UpdateChecker.UpdateInfo?
    @Published private(set) var isInstalling = false
    @Published private(set) var isCheckingForUpdate = false
    @Published private(set) var updateCheckOutcome: UpdateCheckOutcome?
    @Published var settings: AlertSettings {
        didSet { snapshot.settings = settings; persist() }
    }

    private var snapshot: Persistence.Snapshot
    private var pricing: PricingTable
    private let scanner = TranscriptScanner()
    private var timer: Timer?
    private var lastUpdateCheck: Date?

    init() {
        self.snapshot = Persistence.loadSnapshot()
        self.pricing = Persistence.loadPricing()
        self.settings = snapshot.settings

        // Migration: a full re-scan is required when the record→aggregate fold gains a new
        // field that can only be computed at fold time (it can't be backfilled from summed
        // aggregates, and deduped message IDs are never re-folded otherwise).
        //   v1: perProject tracking.
        //   v2: taxableCacheRead (context-tax tokens) — added for the context_bloat insight.
        // Clearing scan state and aggregates forces the next scan to re-process every JSONL
        // file. Settings and alert state are preserved.
        if snapshot.dataVersion < 2 {
            AppLog.shared.info("migrating to dataVersion 2: clearing scan state to backfill context-tax tokens", category: "migration")
            snapshot.scanState = ScanState()
            snapshot.aggregates = [:]
            snapshot.dataVersion = 2
            Persistence.save(snapshot)
        }

        // If the loaded pricing is newer than what was used to compute the cached
        // aggregates, reapply costs now so stale prices never reach the display
        // layer.  This covers the case where the app is rebuilt with a corrected
        // pricing.json but state.json still holds aggregates from the old rates.
        let loadedVersion = pricing.version ?? 0
        if loadedVersion > snapshot.pricingVersion {
            Aggregator.recost(&snapshot.aggregates, pricing: pricing)
            snapshot.pricingVersion = loadedVersion
            Persistence.save(snapshot)
        }

        rebuildPublished()
        startAutoRefresh()
        Task { await checkForUpdate() }
    }

    /// Refresh now and then on a fixed interval so the menu-bar total stays current
    /// even while the popover is closed.
    func startAutoRefresh(interval: TimeInterval = 60) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: - Derived values

    var todayKey: String { DayBucket.localDay(from: Date()) }

    var todayCost: Double { snapshot.aggregates[todayKey]?.totalCost ?? 0 }

    var todayCostString: String { Fmt.usd(todayCost) }

    /// Red when over the daily budget, default otherwise.
    var isOverDailyBudget: Bool {
        guard let limit = settings.dailyThreshold else { return false }
        return todayCost >= limit
    }

    var monthCost: Double {
        let prefix = String(todayKey.prefix(7))
        return snapshot.aggregates.values
            .filter { $0.day.hasPrefix(prefix) }
            .reduce(0) { $0 + $1.totalCost }
    }

    var windowTotalCost: Double { days.reduce(0) { $0 + $1.totalCost } }

    /// Fractional change in average daily spend: last 7 complete days vs prior 7.
    /// Excludes today (partial day). Returns nil if data is too sparse or change < 5%.
    var spendTrend: Double? {
        let recent = (1...7).map { snapshot.aggregates[DayBucket.day(daysAgo: $0)]?.totalCost ?? 0 }
        let prior  = (8...14).map { snapshot.aggregates[DayBucket.day(daysAgo: $0)]?.totalCost ?? 0 }
        let recentAvg = recent.reduce(0, +) / 7.0
        let priorAvg  = prior.reduce(0, +)  / 7.0
        guard priorAvg > 0.5 else { return nil }
        let change = (recentAvg - priorAvg) / priorAvg
        return abs(change) >= 0.05 ? change : nil
    }

    var aggregates: [String: DailyAggregate] { snapshot.aggregates }

    var pricingFilePath: String { Persistence.pricingURL.path }

    // MARK: - Refresh

    func refresh() {
        if lastUpdateCheck.map({ Date().timeIntervalSince($0) > 21600 }) ?? false {
            Task { await checkForUpdate() }
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        let currentState = snapshot.scanState

        Task {
            // Scan off the main actor; value types cross the boundary safely.
            let result = await Task.detached(priority: .utility) { [scanner] in
                scanner.scan(state: currentState)
            }.value

            self.apply(result)
            self.isRefreshing = false
            self.lastRefresh = Date()
        }
    }

    private func apply(_ result: TranscriptScanner.Result) {
        if !result.records.isEmpty {
            AppLog.shared.info("scan: \(result.records.count) new record(s), \(result.existingPaths.count) file(s)", category: "scan")
        }
        var state = result.state
        snapshot.todayConcurrency = result.concurrency
        Aggregator.fold(records: result.records, into: &snapshot.aggregates, pricing: pricing)

        let cutoff = DayBucket.day(daysAgo: Persistence.retentionDays - 1)
        Aggregator.prune(&snapshot.aggregates, onOrAfter: cutoff)

        let seenCutoff = DayBucket.day(daysAgo: Persistence.retentionDays - 1 + Persistence.seenIDBufferDays)
        state.prune(existingPaths: result.existingPaths, retainSeenIDsOnOrAfter: seenCutoff)
        snapshot.scanState = state

        rebuildPublished()
        runAlerts()
        runTips()
        persist()
    }

    /// Reload pricing.json from disk and recompute all costs.
    func reloadPricing() {
        pricing = Persistence.loadPricing()
        Aggregator.recost(&snapshot.aggregates, pricing: pricing)
        snapshot.pricingVersion = pricing.version ?? 0
        rebuildPublished()
        runTips()
        persist()
    }

    private func runTips() {
        let detected = PatternDetector.detect(aggregates: snapshot.aggregates, settings: settings, concurrency: snapshot.todayConcurrency, pricing: pricing)
        tips = detected
        guard settings.tipsEnabled else { return }
        let toNotify = PatternDetector.tipsToNotify(
            insights: detected,
            lastTipDay: snapshot.lastTipDay,
            today: todayKey
        )
        for id in toNotify {
            if let insight = detected.first(where: { $0.id == id }) {
                AlertManager.shared.sendTip(insight)
                snapshot.lastTipDay[id] = todayKey
            }
        }
    }

    private func runAlerts() {
        let fired = AlertManager.shared.evaluate(
            todayCost: todayCost,
            monthCost: monthCost,
            settings: settings,
            lastAlertDay: snapshot.lastAlertDay,
            today: todayKey
        )
        snapshot.lastAlertDay = fired
    }

    private func rebuildPublished() {
        let byDay = snapshot.aggregates
        days = (0..<Persistence.displayDays).map { offset in
            let key = DayBucket.day(daysAgo: offset)
            return byDay[key] ?? DailyAggregate(day: key)
        }

        var totals: [String: Double] = [:]
        for agg in byDay.values {
            for (dir, pu) in agg.perProject {
                totals[dir, default: 0] += pu.cost
            }
        }
        projectTotals = totals
            .map { (dir: $0.key, name: TranscriptScanner.projectDisplayName(from: $0.key), cost: $0.value) }
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
    }

    func installUpdate() {
        guard let update = availableUpdate, !isInstalling else { return }
        guard let downloadURL = update.downloadURL else {
            UpdateChecker.openReleasesPage()
            return
        }
        isInstalling = true
        Task {
            do {
                try await UpdateInstaller.install(from: downloadURL)
            } catch {
                AppLog.shared.error("update install failed: \(error)", category: "updates")
                isInstalling = false
                UpdateChecker.openReleasesPage()
            }
        }
    }

    func forceCheckForUpdate() {
        lastUpdateCheck = nil
        updateCheckOutcome = nil
        Task { await checkForUpdate() }
    }

    private func checkForUpdate() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        lastUpdateCheck = Date()
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if let update = await UpdateChecker.checkForUpdate(current: current) {
            AppLog.shared.info("update available: \(update.version)", category: "updates")
            availableUpdate = update
            updateCheckOutcome = .available(update.version)
        } else {
            AppLog.shared.info("update check complete — up to date (current: \(current.isEmpty ? "dev" : current))", category: "updates")
            updateCheckOutcome = .upToDate
        }
        isCheckingForUpdate = false
    }

    private func persist() {
        Persistence.save(snapshot)
    }
}
