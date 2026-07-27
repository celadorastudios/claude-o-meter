import SwiftUI
import Charts

/// Pure, view-independent scaling/positioning decisions shared by `HistoryChart` and
/// `HourlyChart`. Extracted so the branching logic can be unit-tested directly (the chart
/// `body` properties that use it are not reachable from XCTest).
enum ChartScaling {

    /// Upper bound for a chart's Y axis: the taller of the data's peak and any configured
    /// limit line, plus 10% headroom so nothing renders flush against the top edge. Floored
    /// at a small positive value so an all-zero chart still has a sane, non-degenerate scale.
    static func yMax(dataMax: Double, limit: Double?, floor: Double = 0.01) -> Double {
        max(max(dataMax, floor), limit ?? 0) * 1.1
    }

    /// Computes the tallest bar in weekly mode, accounting for both actual cost and the
    /// projection ghost bar so the y-axis doesn't clip early in the week.
    static func weeklyDataMax(
        bucketActuals: [Double],
        bucketProjections: [Double]
    ) -> Double {
        let combined = zip(bucketActuals, bucketProjections).map { $0 + $1 }
        return max(combined.max() ?? 1.0, 1.0)
    }

    /// Which side of the limit rule its label sits on, chosen to stay clear of the data:
    /// - **below** while the data stays under budget — the line sits high in the plot, so the
    ///   gap beneath it is clear and a label above would clip the top edge.
    /// - **above** once the data reaches or crosses the limit — the bars/line now fill the
    ///   space below the line, so the label goes above them.
    /// With no positive limit there is no rule to annotate; the position is irrelevant, so we
    /// return `.bottom` by convention.
    static func alertAnnotationPosition(dataMax: Double, limit: Double?) -> AnnotationPosition {
        guard let limit, limit > 0 else { return .bottom }
        return dataMax >= limit ? .top : .bottom
    }
}
