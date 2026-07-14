import SwiftUI
import Charts

struct HistoryChart: View {
    enum Mode: String, CaseIterable, Identifiable {
        case hourly = "Hourly"
        case daily = "Daily"
        case month = "Monthly"
        var id: String { rawValue }
    }

    let days: [DailyAggregate]                  // 30-day window, newest first (Daily mode)
    let allAggregates: [String: DailyAggregate] // full store history (Monthly mode)
    let todayKey: String
    let mode: Mode
    let dailyLimit: Double?
    let monthlyLimit: Double?
    let viewingMonth: String                     // "YYYY-MM"

    @State private var selectedDay: String?
    @State private var hoverX: CGFloat?

    // MARK: - Data shapes

    private struct StackPoint: Identifiable {
        let day: String
        let model: String
        let cost: Double
        var id: String { "\(day)-\(model)" }
    }

    private struct ProjectionBar: Identifiable {
        let day: String
        let cost: Double
        var id: String { day }
    }

    private struct CumulativePoint: Identifiable {
        let day: String
        let value: Double
        var id: String { day }
    }

    // MARK: - Data

    /// Full 30-day window oldest→newest, gap-filled (Daily mode).
    private var ordered: [DailyAggregate] {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return (0..<Persistence.displayDays).reversed().map { offset in
            let key = DayBucket.day(daysAgo: offset)
            return byDay[key] ?? DailyAggregate(day: key)
        }
    }

    /// Models seen in any aggregate, in stable display order.
    private var allKnownModels: [String] {
        let source: [(String, DailyAggregate)]
        if mode == .daily {
            source = ordered.map { ($0.day, $0) }
        } else {
            source = currentMonthDays.compactMap { day in allAggregates[day].map { (day, $0) } }
        }
        let all = Set(source.flatMap { $0.1.perModel.values.filter { $0.cost > 0 }.map { $0.model } })
        let preferred = ["haiku", "sonnet", "opus", "synthetic", "unknown"]
        let inOrder = preferred.filter { all.contains($0) }
        let rest = all.subtracting(preferred).sorted()
        return inOrder + rest
    }

    private var activeModels: [String] { allKnownModels }

    // Daily mode: 30-day stacked bars
    private var stackedPoints: [StackPoint] {
        let models = allKnownModels
        guard !models.isEmpty else { return [] }
        return ordered.flatMap { agg in
            models.map { model in
                let cost = agg.perModel[model]?.cost ?? 0
                return StackPoint(day: agg.day, model: model, cost: max(cost, 0.0001))
            }
        }
    }

    /// All calendar days in `viewingMonth`, oldest→newest.
    private var currentMonthDays: [String] {
        let parts = viewingMonth.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return [] }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let firstDay = Calendar.current.date(from: comps),
              let range = Calendar.current.range(of: .day, in: .month, for: firstDay)
        else { return [] }
        return range.map { day in String(format: "%04d-%02d-%02d", year, month, day) }
    }

    private var isCurrentMonth: Bool { viewingMonth == String(todayKey.prefix(7)) }

    /// "Last day" for the viewed month — either today (current) or the month's last day (past).
    private var lastActualDay: String {
        isCurrentMonth ? todayKey : (currentMonthDays.last ?? todayKey)
    }

    // Monthly mode: stacked bars for actual days
    private var monthStackedPoints: [StackPoint] {
        let models = allKnownModels
        guard !models.isEmpty else { return [] }
        return currentMonthDays.filter { $0 <= lastActualDay }.flatMap { day in
            models.map { model in
                let cost = allAggregates[day]?.perModel[model]?.cost ?? 0
                return StackPoint(day: day, model: model, cost: max(cost, 0.0001))
            }
        }
    }

    /// Per-day forecasts for future days in the current month (empty for past months).
    private var spendForecasts: [SpendProjector.DayForecast] {
        guard isCurrentMonth else { return [] }
        let futureDays = currentMonthDays.filter { $0 > todayKey }
        return SpendProjector.forecast(
            aggregates: allAggregates,
            futureDays: futureDays,
            todayKey: todayKey
        )
    }

    private var projectionBars: [ProjectionBar] {
        spendForecasts.map { ProjectionBar(day: $0.day, cost: $0.cost) }
    }

    /// Running cumulative total for actual days in the viewed month.
    private var monthCumulativePoints: [CumulativePoint] {
        var running = 0.0
        return currentMonthDays.filter { $0 <= lastActualDay }.map { day in
            running += allAggregates[day]?.totalCost ?? 0
            return CumulativePoint(day: day, value: running)
        }
    }

    /// Projected cumulative continuation (current month only).
    private var projectionCumulativePoints: [CumulativePoint] {
        guard !spendForecasts.isEmpty else { return [] }
        let base = monthCumulativePoints.last?.value ?? 0
        return spendForecasts.reduce(into: (points: [CumulativePoint](), running: base)) { acc, f in
            acc.running += f.cost
            acc.points.append(CumulativePoint(day: f.day, value: acc.running))
        }.points
    }

    /// The tallest point the data reaches: the projected/actual cumulative total in Monthly
    /// mode, or the highest single day's bar in Daily mode. Decides which side of the limit
    /// line is clear for its label.
    private var dataMax: Double {
        if mode == .month {
            let top = projectionCumulativePoints.last?.value
                ?? monthCumulativePoints.last?.value
                ?? 1.0
            return max(top, 1.0)
        }
        return ordered.map { $0.totalCost }.max() ?? 1.0
    }

    private var yMax: Double {
        ChartScaling.yMax(dataMax: dataMax, limit: activeLimit, floor: 1.0)
    }

    private var alertAnnotationPosition: AnnotationPosition {
        ChartScaling.alertAnnotationPosition(dataMax: dataMax, limit: activeLimit)
    }

    private var labelDays: [String] {
        let keys = ordered.map { $0.day }
        guard keys.count > 1 else { return keys }
        let step = max(1, keys.count / 4)
        var picks = Array(stride(from: 0, to: keys.count, by: step)).map { keys[$0] }
        if let last = keys.last, picks.last != last { picks.append(last) }
        return picks
    }

    private var monthLabelDays: [String] {
        let allDays = currentMonthDays
        guard !allDays.isEmpty else { return [] }
        var picks = allDays.filter { day in
            guard let d = day.split(separator: "-").last.flatMap({ Int($0) }) else { return false }
            return d == 1 || d % 5 == 0
        }
        if let last = allDays.last, picks.last != last { picks.append(last) }
        return picks
    }

    private var activeLimit: Double? { mode == .daily ? dailyLimit : monthlyLimit }

    // MARK: - Lookup helpers

    private func totalCost(for day: String) -> Double {
        if mode == .month { return allAggregates[day]?.totalCost ?? 0 }
        return ordered.first { $0.day == day }?.totalCost ?? 0
    }

    private func modelBreakdown(for day: String) -> [(model: String, cost: Double)] {
        let models = allKnownModels
        guard !models.isEmpty else { return [] }
        let agg = mode == .month ? allAggregates[day] : ordered.first(where: { $0.day == day })
        return models.map { model in (model, agg?.perModel[model]?.cost ?? 0) }
    }

    private func tooltipView(for day: String) -> some View {
        let projected = mode == .month && day > todayKey
        let dailyCost: Double = projected
            ? (projectionBars.first { $0.day == day }?.cost ?? 0)
            : totalCost(for: day)
        let cumulative: Double? = mode == .month
            ? (projected
                ? projectionCumulativePoints.first { $0.day == day }?.value
                : monthCumulativePoints.first { $0.day == day }?.value)
            : nil
        let breakdown = projected ? [] : modelBreakdown(for: day)

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Fmt.dayLabel(day))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(projected ? "~\(Fmt.usd(dailyCost))" : Fmt.usd(dailyCost))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(projected ? Color.secondary : Color.primary)
            }
            if let mtd = cumulative {
                HStack {
                    Text(projected ? "Projected MTD" : "MTD")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(projected ? "~\(Fmt.usd(mtd))" : Fmt.usd(mtd))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(projected ? Color.secondary : Color.primary)
                }
            }
            if !projected, !breakdown.isEmpty {
                Divider().opacity(0.5)
                ForEach(breakdown, id: \.model) { item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ModelColor.color(for: item.model))
                            .frame(width: 6, height: 6)
                        Text(item.model)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(Fmt.usd(item.cost))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)))
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                if mode == .daily {
                    ForEach(stackedPoints) { p in
                        BarMark(x: .value("Day", p.day), y: .value("Cost", p.cost))
                            .foregroundStyle(by: .value("Model", p.model))
                            .opacity(selectedDay == nil || selectedDay == p.day ? 1.0 : 0.3)
                    }
                } else {
                    // Actual daily bars (stacked by model)
                    ForEach(monthStackedPoints) { p in
                        BarMark(x: .value("Day", p.day), y: .value("Cost", p.cost))
                            .foregroundStyle(by: .value("Model", p.model))
                            .opacity(selectedDay == nil || selectedDay == p.day ? 1.0 : 0.3)
                    }
                    // Ghost bars for projected future days (current month only)
                    ForEach(projectionBars) { p in
                        BarMark(x: .value("Day", p.day), y: .value("Cost", p.cost))
                            .foregroundStyle(Color.secondary.opacity(0.22))
                            .opacity(selectedDay == nil || selectedDay == p.day ? 1.0 : 0.3)
                    }
                    // Cumulative spend line
                    ForEach(monthCumulativePoints) { p in
                        LineMark(x: .value("Day", p.day), y: .value("Total", p.value))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Day", p.day), y: .value("Total", p.value))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(selectedDay == p.day ? 40 : 14)
                    }
                    // Projected cumulative continuation (dashed)
                    ForEach(projectionCumulativePoints) { p in
                        LineMark(x: .value("Day", p.day), y: .value("Total", p.value))
                            .foregroundStyle(Color.accentColor.opacity(0.4))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }

                if let limit = activeLimit, limit > 0 {
                    RuleMark(y: .value("Limit", limit))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: alertAnnotationPosition, alignment: .leading, spacing: 2) {
                            Text("\(mode == .daily ? "Daily" : "Monthly") alert · \(Fmt.usd(limit))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.9)))
                        }
                }

                if let d = selectedDay {
                    RuleMark(x: .value("Day", d))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(
                domain: activeModels,
                range: activeModels.map { ModelColor.color(for: $0) }
            )
            .chartXScale(domain: mode == .month ? currentMonthDays : ordered.map { $0.day })
            .chartYScale(domain: 0...yMax)
            .chartLegend(.hidden)
            .chartXAxis {
                if mode == .month {
                    AxisMarks(values: monthLabelDays) { value in
                        if let s = value.as(String.self) {
                            AxisValueLabel { Text(monthDayLabel(s)).font(.system(size: 11)) }
                        }
                    }
                } else {
                    AxisMarks(values: labelDays) { value in
                        if let s = value.as(String.self) {
                            AxisValueLabel { Text(shortLabel(s)).font(.system(size: 11)) }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let d = value.as(Double.self) {
                            Text(Fmt.usd(d)).font(.system(size: 11))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plotFrame = proxy.plotFrame {
                        let rect = geo[plotFrame]
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let p):
                                    if let day = proxy.value(atX: p.x - rect.minX, as: String.self),
                                       day != selectedDay {
                                        selectedDay = day
                                        hoverX = p.x
                                    }
                                case .ended:
                                    selectedDay = nil
                                    hoverX = nil
                                }
                            }
                            .gesture(
                                SpatialTapGesture().onEnded { v in
                                    selectedDay = proxy.value(atX: v.location.x - rect.minX, as: String.self)
                                    hoverX = v.location.x
                                }
                            )
                    }
                }
            }
            .overlay {
                if let d = selectedDay, let hx = hoverX {
                    GeometryReader { geo in
                        let tipW: CGFloat = 180
                        let clampedX = max(tipW / 2 + 4, min(hx, geo.size.width - tipW / 2 - 4))
                        tooltipView(for: d)
                            .frame(width: tipW)
                            .position(x: clampedX, y: 55)
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 115)

            // Compact legend
            HStack(spacing: 10) {
                ForEach(activeModels, id: \.self) { model in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ModelColor.color(for: model))
                            .frame(width: 6, height: 6)
                        Text(model == "unknown" ? "unknown*" : model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if mode == .month, !projectionBars.isEmpty {
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text("projected")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)
        }
    }

    private func shortLabel(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    private func monthDayLabel(_ day: String) -> String {
        guard let d = day.split(separator: "-").last.flatMap({ Int($0) }) else { return day }
        return "\(d)"
    }
}
