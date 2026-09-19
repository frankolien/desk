import DeskUI
import SwiftUI
import WidgetKit

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let glance: PortfolioGlance?
}

struct PortfolioProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: .now, glance: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        let glance = PortfolioGlance.load()
        completion(PortfolioEntry(date: .now, glance: glance ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        // Desk reloads this whenever a figure changes; the schedule is only a backstop.
        let entry = PortfolioEntry(date: .now, glance: PortfolioGlance.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1_800))))
    }
}

struct PortfolioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PortfolioGlance.widgetKind, provider: PortfolioProvider()) { entry in
            PortfolioWidgetView(glance: entry.glance, family: family)
                .containerBackground(for: .widget) { DeskColor.night.color }
        }
        .configurationDisplayName("Portfolio")
        .description("Your collateral and open positions, from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }

    @Environment(\.widgetFamily) private var family
}

#Preview(as: .systemMedium) {
    PortfolioWidget()
} timeline: {
    PortfolioEntry(date: .now, glance: .preview)
    PortfolioEntry(date: .now, glance: nil)
}
