import Charts
import DeskPerpl
import DeskUI
import SwiftUI

/// What holding a position on this market has cost over the last week. A positive rate
/// means longs pay shorts; a negative one, shorts pay longs.
struct FundingHistoryView: View {
    let market: MarketModel
    @State private var events: [MarketFunding] = []
    @State private var loaded = false

    private var current: MarketFunding? { events.last ?? market.market?.funding }
    private var weekMicros: Int64 { events.reduce(0) { $0 + $1.rateMicros } }
    /// The average rate per interval in each six-hour block. A raw series at one event
    /// every few dozen minutes flips too often to read as anything but noise.
    private struct Bucket: Identifiable {
        let start: Date
        let percent: Double
        var id: Date { start }
    }

    private var buckets: [Bucket] {
        let width: Double = 6 * 3_600
        let grouped = Dictionary(grouping: events) { floor(Double($0.observedAt.timestampMilliseconds) / 1_000 / width) }
        return grouped.keys.sorted().map { key in
            let rates = grouped[key] ?? []
            let average = Double(rates.reduce(0) { $0 + $1.rateMicros }) / Double(max(rates.count, 1)) / 10_000
            return Bucket(start: Date(timeIntervalSince1970: key * width), percent: average)
        }
    }

    /// From zero to a little past the largest block on each side that has one, so a week
    /// that never flipped uses the whole height.
    private var domain: ClosedRange<Double> {
        let values = buckets.map(\.percent)
        let top = max((values.max() ?? 0) * 1.25, 0)
        let bottom = min((values.min() ?? 0) * 1.25, 0)
        return top == bottom ? -0.0005...0.0005 : bottom...top
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Funding")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                if let seconds = market.market?.fundingIntervalSeconds {
                    Text("every \(interval(seconds))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }

            if let current {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.percent(current.rateMicros, digits: 4))
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(current.rateMicros == 0 ? "No one pays" : current.rateMicros > 0 ? "Longs pay shorts" : "Shorts pay longs")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }

            if events.count > 1 {
                Chart {
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.white.opacity(0.14))
                        .lineStyle(StrokeStyle(lineWidth: 0.6))
                    ForEach(buckets) { bucket in
                        BarMark(
                            x: .value("Time", bucket.start),
                            y: .value("Rate", bucket.percent),
                            width: .fixed(6))
                            .foregroundStyle(DeskColor.action.color.opacity(bucket.percent >= 0 ? 0.9 : 0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                }
                .chartYScale(domain: domain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                        AxisValueLabel {
                            if let rate = value.as(Double.self) {
                                Text((rate < 0 ? Direction.minus : "") + String(format: "%.3f%%", abs(rate)))
                            }
                        }
                        .foregroundStyle(DeskColor.nightMuted.color)
                    }
                }
                .frame(height: 110)

                Text(weekLine)
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DeskColor.nightMuted.color)
            } else if loaded {
                Text("No funding history for this market yet.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
        .padding(16)
        .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: market.symbol) {
            events = await market.fundingHistory() ?? []
            loaded = true
        }
    }

    /// The week as a share of position size, from a long's side.
    private var weekLine: String {
        let share = Self.percent(abs(weekMicros), digits: 3, signed: false)
        if weekMicros == 0 { return "Over 7 days funding netted to zero." }
        return weekMicros > 0
            ? "Over 7 days a long paid \(share) of its size; a short received it."
            : "Over 7 days a short paid \(share) of its size; a long received it."
    }

    private func interval(_ seconds: Int) -> String {
        seconds % 3_600 == 0 ? "\(seconds / 3_600)h" : "\(seconds / 60) min"
    }

    /// Micros of notional as a percentage: 40 is 0.0040%.
    static func percent(_ micros: Int64, digits: Int, signed: Bool = true) -> String {
        let value = Double(micros) / 10_000
        let text = String(format: "%.\(digits)f%%", abs(value))
        guard signed else { return text }
        return (value > 0 ? "+" : value < 0 ? Direction.minus : "") + text
    }
}
