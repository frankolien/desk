import DeskUI
import SwiftUI
import WidgetKit

struct WatchlistEntry: TimelineEntry {
    let date: Date
    let glance: WatchlistGlance?
}

struct WatchlistProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchlistEntry {
        WatchlistEntry(date: .now, glance: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchlistEntry) -> Void) {
        let glance = WatchlistGlance.load()
        completion(WatchlistEntry(date: .now, glance: glance ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchlistEntry>) -> Void) {
        let entry = WatchlistEntry(date: .now, glance: WatchlistGlance.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1_800))))
    }
}

struct WatchlistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchlistGlance.widgetKind, provider: WatchlistProvider()) { entry in
            WatchlistWidgetView(glance: entry.glance, family: family)
                .containerBackground(for: .widget) { DeskColor.night.color }
        }
        .configurationDisplayName("Watchlist")
        .description("The markets you saved, at their latest prices.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }

    @Environment(\.widgetFamily) private var family
}

#Preview(as: .systemMedium) {
    WatchlistWidget()
} timeline: {
    WatchlistEntry(date: .now, glance: .preview)
    WatchlistEntry(date: .now, glance: nil)
}
