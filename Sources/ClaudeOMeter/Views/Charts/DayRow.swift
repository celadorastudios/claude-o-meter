import SwiftUI

/// One day in the history list; expands to show per-model breakdown.
struct DayRow: View {
    let day: DailyAggregate

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(Fmt.dayLabel(day.day))
                        .font(.system(size: 12))
                    Spacer()
                    Text(Fmt.tokens(day.totalTokens))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(Fmt.usd(day.totalCost))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(day.sortedModels, id: \.model) { m in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ModelColor.color(for: m.model))
                                .frame(width: 7, height: 7)
                            Text(m.model == "unknown" ? "Unknown*" : m.model.capitalized)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            Text(Fmt.tokens(m.usage.total))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(Fmt.usd(m.cost))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, 2)
            }
        }
    }
}
