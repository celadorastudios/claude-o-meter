import Foundation

/// Detects when the current session is burning through expensive models and fires
/// a real-time notification suggesting a cheaper alternative.
///
/// Triggers when Opus spend in the last `windowMinutes` exceeds `costThreshold`.
/// Fires at most once per `cooldownMinutes` to avoid notification spam.
enum SessionNudge {
    static let windowMinutes = 20
    static let costThreshold = 10.0
    static let cooldownMinutes = 60

    struct Decision: Equatable, Sendable {
        let shouldNudge: Bool
        let opusCost: Double
        let windowMinutes: Int
        let suggestion: String
    }

    /// Check whether the current session warrants a model-switch nudge.
    /// Examines today's hourly data for Opus spend within the recent window.
    static func evaluate(
        todayAggregate: DailyAggregate?,
        lastNudgeTime: Date?,
        now: Date = Date()
    ) -> Decision {
        guard let agg = todayAggregate else {
            return Decision(shouldNudge: false, opusCost: 0, windowMinutes: windowMinutes, suggestion: "")
        }

        if let lastNudge = lastNudgeTime {
            let elapsed = now.timeIntervalSince(lastNudge) / 60.0
            if elapsed < Double(cooldownMinutes) {
                return Decision(shouldNudge: false, opusCost: 0, windowMinutes: windowMinutes, suggestion: "")
            }
        }

        let opusCost = agg.perModel["opus"]?.cost ?? 0
        let totalCost = agg.totalCost
        guard totalCost > 0 else {
            return Decision(shouldNudge: false, opusCost: 0, windowMinutes: windowMinutes, suggestion: "")
        }

        let opusFraction = opusCost / totalCost
        let currentHour = Calendar.current.component(.hour, from: now)
        let hoursElapsed = max(1.0, Double(currentHour) + Double(Calendar.current.component(.minute, from: now)) / 60.0)
        let opusRate = opusCost / hoursElapsed
        let recentOpusEstimate = opusRate * (Double(windowMinutes) / 60.0)

        let shouldNudge = recentOpusEstimate >= costThreshold && opusFraction > 0.7

        let suggestion: String
        if shouldNudge {
            suggestion = "Today's Opus spend: \(Fmt.usd(opusCost)) (\(Int(opusFraction * 100))% of total). Sonnet delivers comparable results at ~6× lower cost for everyday tasks. Run `/model sonnet` to switch."
        } else {
            suggestion = ""
        }

        return Decision(
            shouldNudge: shouldNudge,
            opusCost: opusCost,
            windowMinutes: windowMinutes,
            suggestion: suggestion
        )
    }
}
