import SwiftUI

/// Stable color per model family so the chart and breakdown stay visually consistent.
enum ModelColor {
    static func color(for family: String) -> Color {
        switch family {
        case "opus":      return Color(red: 0.85, green: 0.45, blue: 0.20) // Claude-ish terracotta
        case "sonnet":    return Color(red: 0.30, green: 0.55, blue: 0.85)
        case "haiku":     return Color(red: 0.35, green: 0.70, blue: 0.45)
        case "fable":     return Color(red: 0.65, green: 0.35, blue: 0.75)
        case "synthetic": return Color.gray
        default:          return Color.purple // unknown -> priced via fallback
        }
    }
}
