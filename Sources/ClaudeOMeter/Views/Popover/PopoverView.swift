import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showProjects = false
    @State private var draftSettings = AlertSettings()
    @State private var chartMode: HistoryChart.Mode = .daily
    @State private var viewingMonth: String = String(DayBucket.localDay(from: Date()).prefix(7))
    // Hourly-mode state is accessed by the PopoverView+Hourly extension (separate file), so it
    // is module-internal rather than file-private.
    @State var viewingDay: String = DayBucket.localDay(from: Date())
    @State var hourlySlices: [HourlySlice]?
    @State var hourlyLoading = false
    @State var hourlyLoadTask: Task<Void, Never>?
    @State private var launchAtLogin = false
    @State private var loginItemNeedsApproval = false
    @State private var showTrendTooltip = false
    @State private var showRootChangeConfirm = false

    var body: some View {
        Group {
            if showAbout {
                aboutPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else if showSettings {
                settingsPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else if showProjects {
                ProjectsPanel { showProjects = false }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                mainPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: 340)
        .animation(.easeInOut(duration: 0.18), value: showSettings)
        .animation(.easeInOut(duration: 0.18), value: showAbout)
        .animation(.easeInOut(duration: 0.18), value: showProjects)
        .onChange(of: store.todayKey) { oldKey, newKey in
            // When the day rolls over at midnight, keep viewingMonth current if the user
            // was viewing the current month.
            let oldMonth = String(oldKey.prefix(7))
            if viewingMonth == oldMonth {
                viewingMonth = String(newKey.prefix(7))
            }
        }
        .onChange(of: store.lastRefresh) { _, _ in
            // The 60s background scan refreshes the store's aggregates (Daily/Monthly stay
            // live), but the Hourly view's slices are recomputed on demand and would otherwise
            // go stale. Reload them when a scan completes while viewing *today* in Hourly mode.
            // Past days are immutable, so they never need a timed refresh.
            if chartMode == .hourly, isToday {
                loadHourlySlices(for: viewingDay, silent: true)
            }
        }
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            HStack(spacing: 8) {
                Picker("", selection: $chartMode) {
                    ForEach(HistoryChart.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: chartMode) { _, newMode in
                    if newMode == .month {
                        viewingMonth = String(store.todayKey.prefix(7))
                    } else if newMode == .hourly {
                        viewingDay = store.todayKey
                        loadHourlySlices(for: store.todayKey)
                    }
                }

                if chartMode == .month {
                    monthNavigator
                } else if chartMode == .hourly {
                    dayNavigator
                } else {
                    Spacer()
                    if let trend = store.spendTrend {
                        spendTrendBadge(trend)
                            .onHover { showTrendTooltip = $0 }
                            .overlay(alignment: .topTrailing) {
                                if showTrendTooltip {
                                    Text(trendTooltip(trend))
                                        .font(.system(size: 11))
                                        .multilineTextAlignment(.leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .frame(width: 220, alignment: .leading)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.2)))
                                        .offset(y: 30)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            .zIndex(1)
            if chartMode == .hourly {
                hourlyChartArea
            } else {
                HistoryChart(
                    days: store.days,
                    allAggregates: store.aggregates,
                    todayKey: store.todayKey,
                    mode: chartMode,
                    dailyLimit: store.settings.dailyThreshold,
                    monthlyLimit: store.settings.monthlyThreshold,
                    viewingMonth: viewingMonth
                )
            }

            projectsCard
            if !store.tips.isEmpty {
                tipsSection
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.days, id: \.day) { day in
                        DayRow(day: day)
                        Divider().opacity(0.4)
                    }
                    if store.days.isEmpty {
                        Text("No usage recorded yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 260)

            if hasUnknown {
                Text("Unknown* models use the fallback rate. Add their exact key to pricing.json to price them correctly.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            Divider()
            mainFooter
        }
        .padding(12)
    }

    // MARK: - Settings panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button(action: { showSettings = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Divider()

            Text("Spend Alerts")
                .font(.system(size: 12, weight: .semibold))

            ThresholdField(label: "Daily alert",
                           value: Binding(
                            get: { draftSettings.dailyThreshold },
                            set: { draftSettings.dailyThreshold = $0 }))
            ThresholdField(label: "Monthly alert",
                           value: Binding(
                            get: { draftSettings.monthlyThreshold },
                            set: { draftSettings.monthlyThreshold = $0 }))

            HStack(spacing: 6) {
                Text("Warn at")
                    .font(.system(size: 11))
                    .frame(width: 90, alignment: .leading)
                Stepper(
                    value: Binding(
                        get: { draftSettings.approachPercent },
                        set: { draftSettings.approachPercent = $0 }
                    ),
                    in: 50...99, step: 5
                ) {
                    Text("\(draftSettings.approachPercent)%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .controlSize(.small)
            }

            Button {
                AlertManager.shared.sendTest()
            } label: {
                Label("Send test alert", systemImage: "bell.badge")
            }
            .font(.system(size: 11))

            Toggle(isOn: Binding(
                get: { draftSettings.tipsEnabled },
                set: { draftSettings.tipsEnabled = $0 }
            )) {
                Text("Show usage tips")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: $launchAtLogin) {
                Text("Start at login")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: launchAtLogin) { _, newValue in
                // Goes through the store so the choice is persisted as intent, not just
                // applied to the system, and survives the bundle moving.
                store.setLaunchAtLogin(newValue)
                loginItemNeedsApproval = LoginItemManager.shared.requiresApproval
            }

            if loginItemNeedsApproval {
                Button("Approve in System Settings →") {
                    LoginItemManager.shared.openSystemSettings()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            }

            Text("Fires once per period, again when approaching. Blank to disable. USD.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Pricing")
                .font(.system(size: 12, weight: .semibold))

            HStack {
                Button("Edit pricing.json") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: store.pricingFilePath))
                }.font(.system(size: 11))
                Button("Reload pricing") { store.reloadPricing() }
                    .font(.system(size: 11))
            }
            Text("Set discountPercent in pricing.json for enterprise discounts, then Reload.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            transcriptSourceSection

            Divider()

            Text("Diagnostics")
                .font(.system(size: 12, weight: .semibold))

            Button {
                AppLog.shared.copyToPasteboard()
            } label: {
                Label("Copy Diagnostic Logs", systemImage: "doc.on.clipboard")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))

            Spacer()

            Divider()

            HStack {
                Button("Cancel") {
                    showSettings = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") { attemptSave() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .confirmationDialog(
            "Change transcript source?",
            isPresented: $showRootChangeConfirm,
            titleVisibility: .visible
        ) {
            Button("Change & Clear History", role: .destructive) { commitSettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the usage history shown here and re-scans from the new location. Your alert thresholds and pricing rates are kept.")
        }
    }

    /// Commit draft settings, prompting first only when the change would move the transcript
    /// root (which clears accumulated history). Unchanged root saves immediately.
    private func attemptSave() {
        let currentRoot = ProjectsRoot.resolve(override: store.settings.projectsConfigDirOverride)
        let draftRoot   = ProjectsRoot.resolve(override: draftSettings.projectsConfigDirOverride)
        if currentRoot != draftRoot {
            showRootChangeConfirm = true
        } else {
            commitSettings()
        }
    }

    private func commitSettings() {
        store.settings = draftSettings
        showSettings = false
    }

    /// Present a native folder picker for the Claude config directory. The chosen path is stored
    /// verbatim; `ProjectsRoot.resolve` appends `projects/` and the "Now scanning" line reflects it.
    private func browseForConfigDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose your Claude config directory (the folder containing projects/)."
        if let current = draftSettings.projectsConfigDirOverride, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            draftSettings.projectsConfigDirOverride = url.path
        }
    }

    private var transcriptSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript Source")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 6) {
                TextField(
                    "~/.claude",
                    text: Binding(
                        get: { draftSettings.projectsConfigDirOverride ?? "" },
                        set: { draftSettings.projectsConfigDirOverride = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

                Button("Browse…") { browseForConfigDir() }
                    .font(.system(size: 11))
                    .controlSize(.small)
            }

            HStack {
                Text("Now scanning: \(store.resolvedRootPath)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if draftSettings.projectsConfigDirOverride != nil {
                    Button("Reset") { draftSettings.projectsConfigDirOverride = nil }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Claude config dir to scan. Blank uses CLAUDE_CONFIG_DIR, else ~/.claude. Changing this clears history.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About panel

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("About")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { showAbout = false }
                    .font(.system(size: 12))
            }

            Divider()

            // Identity
            HStack(spacing: 10) {
                ClaudeMark(size: 28, color: .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude-o-Meter")
                        .font(.system(size: 15, weight: .bold))
                    Text(appVersion == "dev" ? "Development build" : "Version \(appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Text("Real-time Claude Code spend tracker. Reads transcripts locally. Nothing leaves your machine.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Updates
            VStack(alignment: .leading, spacing: 6) {
                Text("Updates")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Group {
                    if let update = store.availableUpdate {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Version \(update.version) available")
                                .font(.system(size: 11))
                            Spacer()
                            Button("Install") { confirmAndInstall(update: update.version) }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .id("available")
                    } else if let failure = store.updateInstallFailure {
                        // A blocked update is the one moment the verification work has to
                        // actually speak. Silently opening the Releases page reads as a
                        // flaky updater and invites a manual download of the very file
                        // that failed the check.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: failure.isSecurityFailure
                                  ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(failure.isSecurityFailure ? .red : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.message)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    Button("Try again") {
                                        store.clearUpdateInstallFailure()
                                        store.forceCheckForUpdate()
                                    }
                                    .font(.system(size: 11))
                                    Button("Dismiss") { store.clearUpdateInstallFailure() }
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .id("installfailed")
                    } else if store.isCheckingForUpdate {
                        HStack(spacing: 6) {
                            SpinningIcon(systemName: "arrow.clockwise", size: 11)
                                .foregroundStyle(.secondary)
                            Text("Checking for updates…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .id("checking")
                    } else if store.updateCheckOutcome == .upToDate {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("You're up to date")
                                .font(.system(size: 11))
                            Spacer()
                            Button("Check again") { store.forceCheckForUpdate() }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                        }
                        .id("uptodate")
                    } else {
                        Button { store.forceCheckForUpdate() } label: {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .id("idle")
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: updateStateKey)
            }

            Divider()

            // Links
            VStack(alignment: .leading, spacing: 6) {
                Text("Links")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Button {
                    NSWorkspace.shared.open(UpdateChecker.projectPageURL)
                } label: {
                    HStack(spacing: 5) {
                        GitHubMark().frame(width: 11, height: 11)
                        Text("Open on GitHub")
                    }
                }
                .font(.system(size: 11))

                Button {
                    NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
                } label: {
                    Label("Releases & Changelog", systemImage: "tag")
                }
                .font(.system(size: 11))
            }

            Divider()

            // Diagnostics
            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Button {
                    AppLog.shared.copyToPasteboard()
                } label: {
                    Label("Copy Diagnostic Logs", systemImage: "doc.on.clipboard")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))

                Text("Includes app version and session activity. No personal data.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
    }

    // MARK: - Projects card

    private var projectsCard: some View {
        Button { showProjects = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.blue)
                    .frame(width: 14)
                projectsCardText
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.blue.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var projectsCardText: some View {
        if let top = store.projectTotals.first {
            Text("Top project: ")
                .font(.system(size: 12))
                .foregroundStyle(Color.blue.opacity(0.8)) +
            Text(top.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.blue) +
            Text(" (\(Fmt.usd(top.cost)))")
                .font(.system(size: 12))
                .foregroundStyle(Color.blue.opacity(0.8))
        } else {
            Text("No project data yet")
                .font(.system(size: 12))
                .foregroundStyle(Color.blue.opacity(0.7))
        }
    }

    // MARK: - Helpers

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.tips) { tip in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(tip.kind == .bad ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tip.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tip.kind == .bad ? Color.orange : Color.green)
                        Text(tip.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tip.kind == .bad
                              ? Color.orange.opacity(0.08)
                              : Color.green.opacity(0.08))
                )
            }
        }
    }

    // MARK: - Month navigation

    private var availableMonths: [String] {
        let months = Set(store.aggregates.keys.compactMap { key -> String? in
            let m = String(key.prefix(7))
            return m.count == 7 ? m : nil
        })
        return months.sorted()
    }

    private var isCurrentMonth: Bool {
        viewingMonth == String(store.todayKey.prefix(7))
    }

    private var hasPreviousMonth: Bool {
        guard let idx = availableMonths.firstIndex(of: viewingMonth) else { return false }
        return idx > availableMonths.startIndex
    }

    private var hasNextMonth: Bool {
        guard let idx = availableMonths.firstIndex(of: viewingMonth) else { return false }
        let next = availableMonths.index(after: idx)
        return next < availableMonths.endIndex
    }

    private static let monthFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"
        return fmt
    }()

    private var viewingMonthFormatted: String {
        let parts = viewingMonth.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return viewingMonth }
        var comps = DateComponents()
        comps.year = year; comps.month = month
        guard let date = Calendar.current.date(from: comps) else { return viewingMonth }
        return Self.monthFormatter.string(from: date)
    }

    // MARK: - Month navigation

    private var monthNavigator: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Button {
                if let idx = availableMonths.firstIndex(of: viewingMonth), idx > availableMonths.startIndex {
                    viewingMonth = availableMonths[availableMonths.index(before: idx)]
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!hasPreviousMonth)
            .foregroundStyle(hasPreviousMonth ? Color.primary : Color.secondary.opacity(0.4))

            Text(viewingMonthFormatted)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 60, alignment: .center)

            Button {
                if let idx = availableMonths.firstIndex(of: viewingMonth) {
                    let next = availableMonths.index(after: idx)
                    if next < availableMonths.endIndex {
                        viewingMonth = availableMonths[next]
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!hasNextMonth)
            .foregroundStyle(hasNextMonth ? Color.primary : Color.secondary.opacity(0.4))

            if !isCurrentMonth {
                Button("Now") {
                    viewingMonth = String(store.todayKey.prefix(7))
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
    }

    private func trendTooltip(_ trend: Double) -> String {
        let pct = String(format: "%.0f%%", abs(trend * 100))
        let direction = trend > 0 ? "up \(pct)" : "down \(pct)"
        return "Spend is \(direction). Avg of last 7 days vs prior 7 days (today excluded)."
    }

    private func spendTrendBadge(_ trend: Double) -> some View {
        let up = trend > 0
        let color: Color = up ? .orange : .green
        return HStack(spacing: 3) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
            Text(String(format: "%.0f%%", abs(trend * 100)))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
    }

    private var hasUnknown: Bool {
        store.days.contains { $0.perModel.keys.contains("unknown") }
    }

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var updatedLabel: String {
        if store.isRefreshing { return "Updating…" }
        guard let t = store.lastRefresh else { return "Not yet updated" }
        return "Updated " + Self.relativeFmt.localizedString(for: t, relativeTo: Date())
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func confirmAndInstall(update: String) {
        let alert = NSAlert()
        alert.messageText = "Install Update?"
        alert.informativeText = "Claude-o-Meter \(update) is available. The app will quit, update, and relaunch automatically."
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.installUpdate()
    }

    // Collapsed state key for SwiftUI transition identity
    private var updateStateKey: String {
        if store.isInstalling { return "installing" }
        if let v = store.availableUpdate?.version { return "available-\(v)" }
        if store.isCheckingForUpdate { return "checking" }
        if store.updateCheckOutcome == .upToDate { return "uptodate" }
        return "idle"
    }

    @ViewBuilder
    private var headerUpdateArea: some View {
        // Version is always visible — only the small indicator to its right changes.
        HStack(spacing: 4) {
            Button { showAbout = true } label: {
                Text(appVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("About Claude-o-Meter")

            // Indicator — each branch has a unique id so SwiftUI transitions between them
            Group {
                if store.isInstalling {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                        .id("installing")
                } else if let update = store.availableUpdate {
                    Button { confirmAndInstall(update: update.version) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 9))
                            Text("v\(update.version)").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .help("Update available — click to install")
                    .id("available-\(update.version)")
                } else if store.isCheckingForUpdate {
                    SpinningIcon(systemName: "arrow.clockwise", size: 9)
                        .foregroundStyle(.secondary)
                        .id("checking")
                } else if store.updateCheckOutcome == .upToDate {
                    Button { store.forceCheckForUpdate() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Up to date — click to check again")
                    .id("uptodate")
                } else {
                    Button { store.forceCheckForUpdate() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Check for updates")
                    .id("idle")
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: updateStateKey)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClaudeMark(size: 16, color: .accentColor)
                Text("Claude-o-Meter")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                headerUpdateArea
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)
                    Text(Fmt.usd(store.todayCost))
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(store.isOverDailyBudget ? Color.red : Color.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 10)

                VStack(alignment: .center, spacing: 2) {
                    Text("MONTH")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)
                    Text(Fmt.usd(store.monthCost))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 10)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("30 DAYS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.5)
                    Text(Fmt.usd(store.windowTotalCost))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var mainFooter: some View {
        HStack {
            Text(updatedLabel)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Export CSV…") { runExport(format: .csv) }
                Button("Export JSON…") { runExport(format: .json) }
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export usage data…")
            Button {
                NSWorkspace.shared.open(UpdateChecker.projectPageURL)
            } label: {
                GitHubMark()
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")
            Button {
                draftSettings = store.settings
                launchAtLogin = LoginItemManager.shared.isEnabled
                loginItemNeedsApproval = LoginItemManager.shared.requiresApproval
                showSettings = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }.buttonStyle(.plain)
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }.buttonStyle(.plain)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12))
            }.buttonStyle(.plain)
        }
    }

    // MARK: - Export

    private func runExport(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        let days = store.days
        let oldest = days.last?.day ?? store.todayKey
        let newest = days.first?.day ?? store.todayKey
        panel.nameFieldStringValue = "claude-usage-\(oldest)-to-\(newest).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let aggregates = store.aggregates
        Task.detached(priority: .utility) {
            do {
                let exportData = try UsageExporter.export(format: format, from: aggregates)
                try exportData.write(to: url, options: .atomic)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - GitHub icon (rendered via Canvas for crisp Retina output)

struct GitHubMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 16
            var p = Path()
            // Simplified Invertocat silhouette — bold enough to read at 13 px
            p.move(to:    CGPoint(x: 8*s, y: 0))
            p.addCurve(to: CGPoint(x: 0, y: 8*s),
                       control1: CGPoint(x: 3.58*s, y: 0),
                       control2: CGPoint(x: 0, y: 3.58*s))
            p.addCurve(to: CGPoint(x: 5.47*s, y: 15.53*s),
                       control1: CGPoint(x: 0, y: 11.54*s),
                       control2: CGPoint(x: 2.29*s, y: 14.5*s))
            p.addCurve(to: CGPoint(x: 6*s, y: 15.24*s),
                       control1: CGPoint(x: 5.86*s, y: 15.57*s),
                       control2: CGPoint(x: 6*s, y: 15.42*s))
            p.addLine(to:  CGPoint(x: 6*s, y: 13.77*s))
            p.addCurve(to: CGPoint(x: 3.31*s, y: 12.74*s),
                       control1: CGPoint(x: 3.77*s, y: 14.19*s),
                       control2: CGPoint(x: 3.31*s, y: 12.74*s))
            p.addCurve(to: CGPoint(x: 2.42*s, y: 11.6*s),
                       control1: CGPoint(x: 2.95*s, y: 11.85*s),
                       control2: CGPoint(x: 2.42*s, y: 11.6*s))
            p.addCurve(to: CGPoint(x: 3.71*s, y: 11.94*s),
                       control1: CGPoint(x: 1.7*s, y: 11.11*s),
                       control2: CGPoint(x: 3.71*s, y: 11.94*s))
            p.addCurve(to: CGPoint(x: 6.03*s, y: 12.61*s),
                       control1: CGPoint(x: 4.42*s, y: 13.16*s),
                       control2: CGPoint(x: 5.57*s, y: 12.81*s))
            p.addCurve(to: CGPoint(x: 6.54*s, y: 11.54*s),
                       control1: CGPoint(x: 6.1*s, y: 12.09*s),
                       control2: CGPoint(x: 6.31*s, y: 11.74*s))
            p.addCurve(to: CGPoint(x: 2.9*s, y: 7.58*s),
                       control1: CGPoint(x: 4.76*s, y: 11.33*s),
                       control2: CGPoint(x: 2.9*s, y: 10.65*s))
            p.addCurve(to: CGPoint(x: 3.72*s, y: 5.43*s),
                       control1: CGPoint(x: 2.9*s, y: 6.71*s),
                       control2: CGPoint(x: 3.21*s, y: 5.99*s))
            p.addCurve(to: CGPoint(x: 3.8*s, y: 3.32*s),
                       control1: CGPoint(x: 3.64*s, y: 5.23*s),
                       control2: CGPoint(x: 3.36*s, y: 4.42*s))
            p.addCurve(to: CGPoint(x: 6.0*s, y: 4.14*s),
                       control1: CGPoint(x: 3.8*s, y: 3.32*s),
                       control2: CGPoint(x: 4.47*s, y: 3.1*s))
            p.addCurve(to: CGPoint(x: 8*s, y: 3.87*s),
                       control1: CGPoint(x: 6.67*s, y: 3.93*s),
                       control2: CGPoint(x: 7.33*s, y: 3.85*s))
            p.addCurve(to: CGPoint(x: 10*s, y: 4.14*s),
                       control1: CGPoint(x: 8.68*s, y: 3.87*s),
                       control2: CGPoint(x: 9.36*s, y: 3.96*s))
            p.addCurve(to: CGPoint(x: 12.2*s, y: 3.32*s),
                       control1: CGPoint(x: 11.53*s, y: 3.1*s),
                       control2: CGPoint(x: 12.2*s, y: 3.32*s))
            p.addCurve(to: CGPoint(x: 12.28*s, y: 5.43*s),
                       control1: CGPoint(x: 12.64*s, y: 4.42*s),
                       control2: CGPoint(x: 12.36*s, y: 5.23*s))
            p.addCurve(to: CGPoint(x: 13.1*s, y: 7.58*s),
                       control1: CGPoint(x: 12.79*s, y: 5.99*s),
                       control2: CGPoint(x: 13.1*s, y: 6.71*s))
            p.addCurve(to: CGPoint(x: 9.45*s, y: 11.53*s),
                       control1: CGPoint(x: 13.1*s, y: 10.65*s),
                       control2: CGPoint(x: 11.23*s, y: 11.32*s))
            p.addCurve(to: CGPoint(x: 10*s, y: 13.01*s),
                       control1: CGPoint(x: 9.74*s, y: 11.77*s),
                       control2: CGPoint(x: 10*s, y: 12.26*s))
            p.addLine(to:  CGPoint(x: 10*s, y: 15.24*s))
            p.addCurve(to: CGPoint(x: 10.53*s, y: 15.53*s),
                       control1: CGPoint(x: 10*s, y: 15.42*s),
                       control2: CGPoint(x: 10.13*s, y: 15.57*s))
            p.addCurve(to: CGPoint(x: 16*s, y: 8*s),
                       control1: CGPoint(x: 13.71*s, y: 14.5*s),
                       control2: CGPoint(x: 16*s, y: 11.54*s))
            p.addCurve(to: CGPoint(x: 8*s, y: 0),
                       control1: CGPoint(x: 16*s, y: 3.58*s),
                       control2: CGPoint(x: 12.42*s, y: 0))
            p.closeSubpath()
            ctx.fill(p, with: .foreground)
        }
    }
}

// MARK: - Continuously spinning SF Symbol (starts on appear, stops on disappear)

private struct SpinningIcon: View {
    let systemName: String
    let size: CGFloat
    @State private var degrees = 0.0

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .light))
            .rotationEffect(.degrees(degrees))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    degrees = 360
                }
            }
    }
}

/// USD threshold input that maps blank -> nil.
private struct ThresholdField: View {
    let label: String
    @Binding var value: Double?
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 90, alignment: .leading)
            Text("$").foregroundStyle(.secondary)
            TextField("none", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 80)
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in commit() }
        }
        .onAppear { text = value.map { String(format: "%g", $0) } ?? "" }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        value = trimmed.isEmpty ? nil : Double(trimmed)
    }
}
