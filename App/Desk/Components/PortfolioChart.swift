import Charts
import DeskUI
import SwiftUI

struct PortfolioChartPoint: Identifiable, Hashable {
    let id: Int
    let date: Date
    let value: Double
}

/// Profile's line on a real time axis: points sit where they happened, a dashed rule marks where the
/// range began, and a finger dragged along it reads the value under it.
struct PortfolioChart: View {
    let points: [PortfolioChartPoint]
    let baseline: Double
    @Binding var selected: PortfolioChartPoint?
    /// Steps between points instead of curving: for values that only change at events.
    var stepped = false

    @State private var scrubDate: Date?

    private var tint: Color {
        let end = (selected ?? points.last)?.value ?? baseline
        return (end >= baseline ? DeskColor.rise : DeskColor.fall).color
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value) + [baseline]
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.12, 0.01)
        return (low - pad)...(high + pad)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), yStart: .value("Base", yDomain.lowerBound), yEnd: .value("Value", point.value))
                    .interpolationMethod(stepped ? .stepEnd : .monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                    .interpolationMethod(stepped ? .stepEnd : .monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            RuleMark(y: .value("Start", baseline))
                .foregroundStyle(Color.white.opacity(0.28))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Selected", selected.date), y: .value("Value", selected.value))
                    .symbolSize(70)
                    .foregroundStyle(tint)
            } else if let last = points.last {
                PointMark(x: .value("Now", last.date), y: .value("Value", last.value))
                    .symbolSize(36)
                    .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXSelection(value: $scrubDate)
        .onChange(of: scrubDate) { _, date in
            guard let date else { selected = nil; return }
            let nearest = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            if nearest != selected {
                selected = nearest
                Haptics.selection()
            }
        }
        .animation(.snappy(duration: 0.25), value: points)
        .accessibilityLabel("Portfolio chart")
    }
}
