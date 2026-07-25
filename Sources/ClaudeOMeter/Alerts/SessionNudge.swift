import Foundation

/// Detects when today's session is burning through Opus and fires a real-time
/// notification suggesting a switch to Sonnet.
///
/// Triggers when:
/// - Today's Opus spend exceeds `opusDailyThreshold` ($30 default)
/// - Opus is more than 70% of today's total spend
/// - At least `cooldownMinutes` since last nudge
enum SessionNudge {
    static let opusDailyThreshold = 30.0
    static let opusFractionThreshold = 0.70
    static let cooldownMinutes = 60

    struct Decision: Equatable, Sendable {
        let shouldNudge: Bool
        let opusCost: Double
        let suggestion: String
    }

    static func evaluate(
        todayAggregate: DailyAggregate?,
        lastNudgeTime: Date?,
        now: Date = Date()
    ) -> Decision {
        guard let agg = todayAggregate else {
            return Decision(shouldNudge: false, opusCost: 0, suggestion: "")
        }

        if let lastNudge = lastNudgeTime {
            let elapsed = now.timeIntervalSince(lastNudge) / 60.0
            if elapsed < Double(cooldownMinutes) {
                return Decision(shouldNudge: false, opusCost: 0, suggestion: "")
            }
        }

        let opusCost = agg.perModel["opus"]?.cost ?? 0
        let totalCost = agg.totalCost
        guard totalCost > 0 else {
            return Decision(shouldNudge: false, opusCost: 0, suggestion: "")
        }

        let opusFraction = opusCost / totalCost
        let shouldNudge = opusCost >= opusDailyThreshold && opusFraction >= opusFractionThreshold

        let suggestion: String
        if shouldNudge {
            suggestion = "Today's Opus spend: \(Fmt.usd(opusCost)) (\(Int(opusFraction * 100))% of total). Sonnet delivers comparable results at ~6× lower cost for everyday tasks. Run `/model sonnet` to switch."
        } else {
            suggestion = ""
        }

        return Decision(shouldNudge: shouldNudge, opusCost: opusCost, suggestion: suggestion)
    }
}
