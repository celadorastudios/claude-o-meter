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

    /// Why an install did not happen, in the user's terms.
    ///
    /// The distinction is the whole point of verifying at all. "This file is not what we
    /// published" and "we could not check" call for different reactions, and reporting
    /// both as a generic failure wastes the check: someone told only that the update
    /// failed will reasonably assume the updater is flaky and go download it by hand,
    /// which is the one thing they must not do when provenance is actually missing.
    enum UpdateInstallFailure: Equatable {
        case unverified(String)    // GitHub holds no attestation for this download
        case unverifiable(String)  // could not reach GitHub to check
        case failed(String)        // download, unzip, or the swap itself

        var message: String {
            switch self {
            case .unverified(let version):
                return "Update to \(version) was blocked: this download is not the file "
                     + "we published. Do not install it manually."
            case .unverifiable(let version):
                return "Couldn't verify update \(version). This doesn't mean the download "
                     + "is unsafe, only that GitHub couldn't be reached to check. Try again."
            case .failed(let version):
                return "Update to \(version) couldn't be installed. Your current version is "
                     + "unchanged."
            }
        }

        /// Only a definitively bad artifact warrants alarming the user.
        var isSecurityFailure: Bool {
            if case .unverified = self { return true }
            return false
        }

        /// Maps an install error onto what the user needs to know.
        static func from(_ error: Error, version: String) -> UpdateInstallFailure {
            guard let verification = error as? UpdateVerifier.VerificationError else {
                return .failed(version)
            }
            switch verification {
            case .notAttested:    return .unverified(version)
            case .couldNotVerify: return .unverifiable(version)
            }
        }
    }

    @Published private(set) var availableUpdate: UpdateChecker.UpdateInfo?
    @Published private(set) var isInstalling = false
    @Published private(set) var isCheckingForUpdate = false
    @Published private(set) var updateCheckOutcome: UpdateCheckOutcome?
    @Published private(set) var updateInstallFailure: UpdateInstallFailure?
    @Published var settings: AlertSettings {
        didSet { applySettingsChange(from: oldValue) }
    }

    private var snapshot: Persistence.Snapshot
    private var pricing: PricingTable
    private var scanner: TranscriptScanner
    private var timer: Timer?
    private var lastUpdateCheck: Date?
    /// Bumped whenever the transcript root changes. A scan captures the epoch at dispatch and its
    /// result is discarded if the epoch no longer matches, so an in-flight old-root scan can never
    /// fold stale records back into a snapshot that a root change just cleared.
    private var scanEpoch = 0

    /// The `projects/` directory currently being scanned, for display in settings.
    var resolvedRootPath: String { scanner.rootDirectory.path }

    init() {
        self.snapshot = Persistence.loadSnapshot()
        self.pricing = Persistence.loadPricing()
        self.settings = snapshot.settings
        let resolvedRoot = ProjectsRoot.resolve(override: snapshot.settings.projectsConfigDirOverride)
        self.scanner = TranscriptScanner(rootDirectory: resolvedRoot)
        AppLog.shared.info("scanning transcript root: \(resolvedRoot.path)", category: "scan")

        // A full re-scan is required when the record→aggregate fold gains a new field that
        // can only be computed at fold time (it can't be backfilled from summed aggregates,
        // and deduped message IDs are never re-folded otherwise). See Persistence.migrate.
        let migration = Persistence.migrate(snapshot)
        if migration.didMigrate {
            AppLog.shared.info("migrating to dataVersion \(Persistence.currentDataVersion): clearing scan state to backfill context-tax tokens", category: "migration")
            snapshot = migration.snapshot
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
        // Off the synchronous init path: init() has to finish before the menu-bar label
        // first paints, and this queries SMAppService. Same treatment as the update check.
        Task { self.reconcileLoginItem() }
    }

    /// Keeps the launch-at-login setting attached to the app after it changes location.
    ///
    /// `SMAppService` registers the running bundle, so the registration does not follow a
    /// move. Anyone stranded by the old hardcoded-`/Applications` updater lands in a new
    /// directory when they reinstall, which would otherwise silently turn their setting
    /// off. See `LoginItemManager.shouldReRegister` for why this only acts on a move.
    private func reconcileLoginItem() {
        // Under `swift run` the main bundle is a build directory, not a .app. Recording
        // that path would overwrite the real install location and make the next genuine
        // launch look like a move.
        let bundleURL = Bundle.main.bundleURL
        guard LoginItemManager.isRegistrableBundle(bundleURL) else { return }

        let manager = LoginItemManager.shared
        let currentPath = LoginItemManager.normalizedPath(bundleURL)
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let previousPath = snapshot.lastBundlePath
        var intent = snapshot.launchAtLogin

        let context = LoginItemManager.launchContext(lastPath: previousPath,
                                                     currentPath: currentPath,
                                                     lastVersion: snapshot.lastVersion,
                                                     currentVersion: currentVersion)

        switch context {
        case .firstRun:
            // Nothing recorded to reason from, so adopt the system's answer as intent.
            //
            // Known limit: a user whose first launch of this build is already *after* a
            // move has nothing to adopt, because the registration was lost before this
            // code ever ran. They are seeded off and re-enable once from the toggle,
            // which reads live status so it shows the truth.
            intent = manager.isEnabled

        case .unchanged:
            // Same bundle, same version, so the system is authoritative: an "off" here is
            // the user's own choice in System Settings. Record it, otherwise a stale "on"
            // would sit in storage and resurrect the setting at some unrelated later move.
            intent = manager.isEnabled

        case .moved:
            // The bundle is not the one the registration was made against, so a system
            // "off" says nothing about what the user wants. Restore their intent instead
            // of reading the change as a decision.
            manager.restoreRegistration(context: context,
                                        intendedEnabled: intent,
                                        detail: "app moved from \(previousPath) to \(currentPath)")

        case .updatedInPlace:
            manager.restoreRegistration(context: context,
                                        intendedEnabled: intent,
                                        detail: "updated in place from \(snapshot.lastVersion) to \(currentVersion)")
        }

        // Committing the path is what marks a move as handled, so it waits until the
        // system actually matches the intent. A refused or unapproved registration
        // therefore retries on the next launch instead of being written off forever.
        let recordPath = LoginItemManager.shouldRecordNewPath(intendedEnabled: intent,
                                                              resultingIsEnabled: manager.isEnabled)

        var changed = false
        if snapshot.launchAtLogin != intent {
            snapshot.launchAtLogin = intent
            changed = true
        }
        if recordPath {
            // Path and version advance together: both describe the bundle the current
            // registration belongs to, so committing one without the other would leave
            // the next launch misclassifying this one.
            if snapshot.lastBundlePath != currentPath {
                snapshot.lastBundlePath = currentPath
                changed = true
            }
            if snapshot.lastVersion != currentVersion {
                snapshot.lastVersion = currentVersion
                changed = true
            }
        }
        guard changed else { return }
        Persistence.save(snapshot)
    }

    /// Records the user's launch-at-login intent alongside applying it, so the setting can
    /// be restored if the bundle later moves.
    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItemManager.shared.setEnabled(enabled)
        guard snapshot.launchAtLogin != enabled else { return }
        snapshot.launchAtLogin = enabled
        Persistence.save(snapshot)
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
        let epoch = scanEpoch

        Task {
            // Scan off the main actor; value types cross the boundary safely.
            let result = await Task.detached(priority: .utility) { [scanner] in
                scanner.scan(state: currentState)
            }.value

            self.isRefreshing = false
            // Discard a scan whose root was swapped out from under it (see scanEpoch): applying
            // its old-root records would undo the clear performed by applySettingsChange. Kick off
            // a fresh scan of the new root, which the in-flight guard had blocked until now.
            guard epoch == self.scanEpoch else {
                self.refresh()
                return
            }
            self.apply(result)
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

    /// React to a `settings` assignment. Always mirrors settings into the snapshot and persists.
    /// When the change moves the resolved transcript root, the scanner is rebuilt and all
    /// accumulated scan state + aggregates are cleared so the display reflects only the new
    /// root (stale data from the old profile would otherwise linger until it aged out).
    private func applySettingsChange(from oldValue: AlertSettings) {
        snapshot.settings = settings

        let oldRoot = ProjectsRoot.resolve(override: oldValue.projectsConfigDirOverride)
        let newRoot = ProjectsRoot.resolve(override: settings.projectsConfigDirOverride)

        guard oldRoot != newRoot else {
            persist()
            return
        }

        AppLog.shared.info("transcript root changed \(oldRoot.path) → \(newRoot.path): clearing scan state and re-scanning", category: "scan")
        // Bump the epoch so any in-flight old-root scan's result is discarded rather than folded
        // back into the cleared snapshot.
        scanEpoch += 1
        scanner = TranscriptScanner(rootDirectory: newRoot)
        snapshot.scanState = ScanState()
        snapshot.aggregates = [:]
        snapshot.todayConcurrency = ConcurrencyStats()
        rebuildPublished()
        persist()
        refresh()
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

    /// Return per-hour cost slices for `day` by scanning the transcript archive off-actor.
    func hourlySlices(for day: String) async -> [HourlySlice] {
        let root = scanner.rootDirectory
        let p = pricing
        return await Task.detached(priority: .utility) {
            TranscriptScanner.scanHourly(for: day, rootDirectory: root, pricing: p)
        }.value
    }

    func installUpdate() {
        guard let update = availableUpdate, !isInstalling else { return }
        guard let downloadURL = update.downloadURL else {
            UpdateChecker.openReleasesPage()
            return
        }
        isInstalling = true
        updateInstallFailure = nil
        Task {
            do {
                try await UpdateInstaller.install(from: downloadURL, version: update.version)
            } catch {
                AppLog.shared.error("update install failed: \(error)", category: "updates")
                isInstalling = false

                let failure = UpdateInstallFailure.from(error, version: update.version)
                updateInstallFailure = failure

                // Only send them to Releases when downloading it by hand is actually the
                // right next step. For a download that failed verification it is the
                // opposite of the right step, so the message stands on its own.
                if !failure.isSecurityFailure {
                    UpdateChecker.openReleasesPage()
                }
            }
        }
    }

    /// Clears a reported install failure, e.g. when the user retries or dismisses it.
    func clearUpdateInstallFailure() {
        updateInstallFailure = nil
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
