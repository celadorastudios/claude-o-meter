import SwiftUI
import Charts

/// Bar chart of per-hour spend for a single day, stacked by model family, with a running
/// cumulative-spend line, a dashed projected continuation (today only), and an optional
/// daily-alert threshold rule. Mirrors `HistoryChart`'s Monthly-mode rendering, bucketed
/// by hour 0–23 of one day instead of days of a month.
struct HourlyChart: View {
    let slices: [HourlySlice]
    var chartHeight: CGFloat = 115
    /// Local hour 0–23 of "now"; used to split actual vs projected. Ignored when `isToday` is false.
    var currentHour: Int = 23
    var isToday: Bool = false
    /// Daily spend alert threshold in USD, if configured.
    var dailyLimit: Double? = nil
    /// Full daily history + today's key, for the history-blended projection. Empty ⇒ no projection.
    var aggregates: [String: DailyAggregate] = [:]
    var todayKey: String = ""

    @State private var selectedHour: String?
    @State private var hoverX: CGFloat?

    private struct StackPoint: Identifiable {
        let hour: String        // zero-padded "00".."23" so lexical order == chronological
        let model: String
        let cost: Double
        var id: String { "\(hour)-\(model)" }
    }

    private struct CumulativePoint: Identifiable {
        let hour: String
        let value: Double
        var id: String { hour }
    }

    private struct ProjectionBar: Identifiable {
        let hour: String
        let cost: Double
        var id: String { hour }
    }

    // MARK: - Keys / models

    /// All 24 hour keys, oldest→newest, zero-padded for stable categorical ordering.
    private var hourKeys: [String] { (0..<24).map { String(format: "%02d", $0) } }

    private func key(_ h: Int) -> String { String(format: "%02d", h) }

    /// Models present in any slice, in stable display order.
    private var allModels: [String] {
        let all = Set(slices.flatMap { $0.perModel.filter { $0.value > 0 }.keys })
        let preferred = ["haiku", "sonnet", "opus", "synthetic", "unknown"]
        return preferred.filter { all.contains($0) } + all.subtracting(preferred).sorted()
    }

    private var byHour: [String: HourlySlice] {
        Dictionary(uniqueKeysWithValues: slices.map { (key($0.hour), $0) })
    }

    // MARK: - Actual bars

    private var stackedPoints: [StackPoint] {
        let models = allModels
        guard !models.isEmpty else { return [] }
        let lookup = byHour
        return hourKeys.flatMap { hk in
            // Floor each model's segment to a hairline so thin slices stay visible — but only
            // for hours that actually have spend. A genuinely idle hour renders flat at zero,
            // matching its "$0.00" tooltip instead of showing a phantom bar.
            let hourHasSpend = (lookup[hk]?.cost ?? 0) > 0
            return models.map { model in
                let cost = lookup[hk]?.perModel[model] ?? 0
                return StackPoint(hour: hk, model: model, cost: hourHasSpend ? max(cost, 0.0001) : 0)
            }
        }
    }

    // MARK: - Projection

    private var hourForecasts: [HourlyProjector.HourForecast] {
        HourlyProjector.forecast(
            slices: slices,
            aggregates: aggregates,
            todayKey: todayKey,
            isToday: isToday
        )
    }

    private var projectionBars: [ProjectionBar] {
        hourForecasts.map { ProjectionBar(hour: key($0.hour), cost: $0.cost) }
    }

    // MARK: - Cumulative line

    /// Running cumulative total across actual hours (all hours for a past day; through the
    /// current hour for today).
    private var cumulativePoints: [CumulativePoint] {
        let lookup = byHour
        let lastActual = isToday ? max(0, min(23, currentHour)) : 23
        var running = 0.0
        return (0...lastActual).map { h in
            running += lookup[key(h)]?.cost ?? 0
            return CumulativePoint(hour: key(h), value: running)
        }
    }

    /// Projected cumulative continuation past the current hour (today only).
    private var projectionCumulativePoints: [CumulativePoint] {
        guard !hourForecasts.isEmpty else { return [] }
        let base = cumulativePoints.last?.value ?? 0
        return hourForecasts.reduce(into: (points: [CumulativePoint](), running: base)) { acc, f in
            acc.running += f.cost
            acc.points.append(CumulativePoint(hour: key(f.hour), value: acc.running))
        }.points
    }

    // MARK: - Scale

    /// The day's cumulative total — projected end-of-day if projecting, else actual-so-far.
    /// This is the highest point the data reaches, so it decides both the Y scale and which
    /// side of the limit line is clear for its label.
    private var dayTotal: Double {
        projectionCumulativePoints.last?.value ?? cumulativePoints.last?.value ?? 0
    }

    private var yMax: Double {
        ChartScaling.yMax(dataMax: dayTotal, limit: dailyLimit)
    }

    private var alertAnnotationPosition: AnnotationPosition {
        ChartScaling.alertAnnotationPosition(dataMax: dayTotal, limit: dailyLimit)
    }

    /// A handful of x-axis labels: 12a, 6a, 12p, 6p, 11p.
    private var labelHours: [String] { [0, 6, 12, 18, 23].map { key($0) } }

    // MARK: - Lookups

    private func slice(for hk: String) -> HourlySlice? {
        guard let h = Int(hk) else { return nil }
        return slices.first { $0.hour == h }
    }

    private func modelBreakdown(for hk: String) -> [(model: String, cost: Double)] {
        let s = slice(for: hk)
        return allModels.map { ($0, s?.perModel[$0] ?? 0) }
    }

    private func tooltipView(for hk: String) -> some View {
        let projected = isToday && (Int(hk) ?? 0) > max(0, min(23, currentHour))
        let hourlyCost: Double = projected
            ? (projectionBars.first { $0.hour == hk }?.cost ?? 0)
            : (slice(for: hk)?.cost ?? 0)
        let cumulative: Double? = projected
            ? projectionCumulativePoints.first { $0.hour == hk }?.value
            : cumulativePoints.first { $0.hour == hk }?.value
        let breakdown = projected ? [] : modelBreakdown(for: hk).filter { $0.cost > 0 }

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hourLabel(hk))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(projected ? "~\(Fmt.usd(hourlyCost))" : Fmt.usd(hourlyCost))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(projected ? Color.secondary : Color.primary)
            }
            if let cum = cumulative {
                HStack {
                    Text(projected ? "Projected total" : "Total so far")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(projected ? "~\(Fmt.usd(cum))" : Fmt.usd(cum))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(projected ? Color.secondary : Color.primary)
                }
            }
            if !breakdown.isEmpty {
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
                // Actual per-hour bars, stacked by model.
                ForEach(stackedPoints) { p in
                    BarMark(x: .value("Hour", p.hour), y: .value("Cost", p.cost))
                        .foregroundStyle(by: .value("Model", p.model))
                        .opacity(selectedHour == nil || selectedHour == p.hour ? 1.0 : 0.3)
                }
                // Ghost bars for projected future hours (today only).
                ForEach(projectionBars) { p in
                    BarMark(x: .value("Hour", p.hour), y: .value("Cost", p.cost))
                        .foregroundStyle(Color.secondary.opacity(0.22))
                        .opacity(selectedHour == nil || selectedHour == p.hour ? 1.0 : 0.3)
                }
                // Cumulative spend line.
                ForEach(cumulativePoints) { p in
                    LineMark(x: .value("Hour", p.hour), y: .value("Total", p.value))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Hour", p.hour), y: .value("Total", p.value))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(selectedHour == p.hour ? 40 : 12)
                }
                // Projected cumulative continuation (dashed).
                ForEach(projectionCumulativePoints) { p in
                    LineMark(x: .value("Hour", p.hour), y: .value("Total", p.value))
                        .foregroundStyle(Color.accentColor.opacity(0.4))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                if let limit = dailyLimit, limit > 0 {
                    RuleMark(y: .value("Limit", limit))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: alertAnnotationPosition, alignment: .leading, spacing: 2) {
                            Text("Daily alert · \(Fmt.usd(limit))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.9)))
                        }
                }

                if let h = selectedHour {
                    RuleMark(x: .value("Hour", h))
                        .foregroundStyle(.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(
                domain: allModels,
                range: allModels.map { ModelColor.color(for: $0) }
            )
            .chartXScale(domain: hourKeys)
            .chartYScale(domain: 0...yMax)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: labelHours) { value in
                    if let s = value.as(String.self) {
                        // Anchor endpoints inward so "12a"/"11p" aren't clipped at the plot edges.
                        let anchor: UnitPoint = s == labelHours.first ? .topLeading
                                              : s == labelHours.last  ? .topTrailing
                                              : .top
                        AxisValueLabel(anchor: anchor, collisionResolution: .disabled) {
                            Text(hourLabel(s)).font(.system(size: 11)).fixedSize()
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
                                    if let hour = proxy.value(atX: p.x - rect.minX, as: String.self),
                                       hour != selectedHour {
                                        selectedHour = hour
                                        hoverX = p.x
                                    }
                                case .ended:
                                    selectedHour = nil
                                    hoverX = nil
                                }
                            }
                            .gesture(
                                SpatialTapGesture().onEnded { v in
                                    selectedHour = proxy.value(atX: v.location.x - rect.minX, as: String.self)
                                    hoverX = v.location.x
                                }
                            )
                    }
                }
            }
            .overlay {
                if let h = selectedHour, let hx = hoverX, hasContent(at: h) {
                    GeometryReader { geo in
                        let tipW: CGFloat = 175
                        let clampedX = max(tipW / 2 + 4, min(hx, geo.size.width - tipW / 2 - 4))
                        tooltipView(for: h)
                            .frame(width: tipW)
                            .position(x: clampedX, y: 55)
                            .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: chartHeight)

            // Compact legend
            HStack(spacing: 10) {
                ForEach(allModels, id: \.self) { model in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(ModelColor.color(for: model))
                            .frame(width: 6, height: 6)
                        Text(model == "unknown" ? "unknown*" : model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if !projectionBars.isEmpty {
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

    /// Whether the hour has any actual or projected spend worth a tooltip.
    private func hasContent(at hk: String) -> Bool {
        if (slice(for: hk)?.cost ?? 0) > 0 { return true }
        return projectionBars.contains { $0.hour == hk }
    }

    private func hourLabel(_ hk: String) -> String {
        guard let h = Int(hk) else { return hk }
        return h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p"
    }
}
