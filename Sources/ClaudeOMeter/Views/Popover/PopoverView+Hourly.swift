import SwiftUI

/// Hourly-mode UI for the main popover: the day navigator (prev/next/Today), the chart area
/// (loading / chart / empty placeholder), and the async slice loader. Split out of
/// `PopoverView` to keep that file focused; all state lives on `PopoverView`.
extension PopoverView {

    // MARK: - Day navigation

    var availableDays: [String] {
        store.days.map { $0.day }.sorted()
    }

    var hasPreviousDay: Bool {
        guard let idx = availableDays.firstIndex(of: viewingDay) else { return false }
        return idx > availableDays.startIndex
    }

    var hasNextDay: Bool {
        guard let idx = availableDays.firstIndex(of: viewingDay) else { return false }
        return availableDays.index(after: idx) < availableDays.endIndex
    }

    var isToday: Bool { viewingDay == store.todayKey }

    var viewingDayFormatted: String { Fmt.dayLabel(viewingDay) }

    var dayNavigator: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Button {
                if let idx = availableDays.firstIndex(of: viewingDay), idx > availableDays.startIndex {
                    let prev = availableDays[availableDays.index(before: idx)]
                    viewingDay = prev
                    loadHourlySlices(for: prev)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!hasPreviousDay)
            .foregroundStyle(hasPreviousDay ? Color.primary : Color.secondary.opacity(0.4))

            Text(viewingDayFormatted)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .center)

            Button {
                if let idx = availableDays.firstIndex(of: viewingDay) {
                    let next = availableDays.index(after: idx)
                    if next < availableDays.endIndex {
                        let nextDay = availableDays[next]
                        viewingDay = nextDay
                        loadHourlySlices(for: nextDay)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!hasNextDay)
            .foregroundStyle(hasNextDay ? Color.primary : Color.secondary.opacity(0.4))

            if !isToday {
                Button("Today") {
                    viewingDay = store.todayKey
                    loadHourlySlices(for: store.todayKey)
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
    }

    // MARK: - Chart area

    /// Height of the hourly bar chart itself; the loading/empty placeholders reserve this plus
    /// `hourlyLegendHeight` so the popover doesn't resize when the chart resolves.
    static var hourlyChartHeight: CGFloat { 115 }
    static var hourlyLegendHeight: CGFloat { 20 }
    static var hourlyAreaHeight: CGFloat { hourlyChartHeight + hourlyLegendHeight }

    @ViewBuilder
    var hourlyChartArea: some View {
        if hourlyLoading {
            HStack {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(height: Self.hourlyAreaHeight)
        } else if let slices = hourlySlices {
            HourlyChart(
                slices: slices,
                chartHeight: Self.hourlyChartHeight,
                currentHour: Calendar.current.component(.hour, from: Date()),
                isToday: isToday,
                dailyLimit: store.settings.dailyThreshold,
                aggregates: store.aggregates,
                todayKey: store.todayKey
            )
        } else {
            Color.clear.frame(height: Self.hourlyAreaHeight)
        }
    }

    /// Recompute the hourly slices for `day`. `silent` (used by the timed background refresh)
    /// keeps the existing chart on screen and skips the loading spinner, so a live "today"
    /// view updates in place instead of flashing "Loading…" every scan cycle.
    ///
    /// Cancels any in-flight load first: rapid prev/next day-navigation would otherwise race
    /// several concurrent scans, and whichever finished last — not the one for the currently
    /// selected day — would win. The result is discarded if the task was cancelled while the
    /// off-actor scan ran.
    func loadHourlySlices(for day: String, silent: Bool = false) {
        hourlyLoadTask?.cancel()
        if !silent {
            hourlySlices = nil
            hourlyLoading = true
        }
        hourlyLoadTask = Task {
            let slices = await store.hourlySlices(for: day)
            if Task.isCancelled { return }
            hourlySlices = slices
            hourlyLoading = false
        }
    }
}
