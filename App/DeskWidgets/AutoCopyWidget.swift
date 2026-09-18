import AppIntents
import DeskUI
import SwiftUI
import WidgetKit

struct AutoCopyEntry: TimelineEntry {
    let date: Date
    let glance: AutoCopyGlance?
    let isPaused: Bool
}

struct AutoCopyProvider: TimelineProvider {
    func placeholder(in context: Context) -> AutoCopyEntry {
        AutoCopyEntry(date: .now, glance: .preview, isPaused: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (AutoCopyEntry) -> Void) {
        let glance = AutoCopyGlance.load()
        completion(context.isPreview && glance?.isSetUp != true
            ? placeholder(in: context)
            : AutoCopyEntry(date: .now, glance: glance, isPaused: AutoCopySwitch.isPaused))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AutoCopyEntry>) -> Void) {
        let entry = AutoCopyEntry(date: .now, glance: AutoCopyGlance.load(), isPaused: AutoCopySwitch.isPaused)
        // Desk reloads this whenever a copy opens or closes; the schedule only rolls "today" over.
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(min(midnight, .now.addingTimeInterval(3_600)))))
    }
}

struct AutoCopyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AutoCopyControl.widgetKind, provider: AutoCopyProvider()) { entry in
            AutoCopyWidgetView(entry: entry)
                .containerBackground(for: .widget) { DeskColor.night.color }
        }
        .configurationDisplayName("Auto-Copy")
        .description("Today's copy trading result, your latest copies and a pause button.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct AutoCopyWidgetView: View {
    let entry: AutoCopyEntry

    @Environment(\.widgetFamily) private var family

    /// A glance written on an earlier day says nothing about today.
    private var today: Double {
        guard let glance = entry.glance, Calendar.current.isDateInToday(glance.updatedAt) else { return 0 }
        return glance.today
    }

    var body: some View {
        if let glance = entry.glance, glance.isSetUp {
            switch family {
            case .accessoryInline:
                Label("Copy \(AutoCopyGlance.money(today)) today", systemImage: entry.isPaused ? "pause.fill" : "square.on.square")
                    .privacySensitive()
            case .accessoryCircular:
                circular(glance)
            case .accessoryRectangular:
                rectangular(glance)
            case .systemMedium:
                medium(glance)
            default:
                small(glance)
            }
        } else {
            empty
        }
    }

    private func header(_ glance: AutoCopyGlance) -> some View {
        HStack(spacing: 6) {
            DeskMark(size: 18)
            Text("Auto-Copy")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Spacer(minLength: 0)
        }
    }

    private func toggle(compact: Bool) -> some View {
        Button(intent: SetAutoCopyIntent(running: entry.isPaused)) {
            Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: compact ? 11 : 12, weight: .bold))
                .foregroundStyle(entry.isPaused ? DeskColor.onAction.color : DeskColor.nightText.color)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(entry.isPaused ? DeskColor.action.color : DeskColor.nightChip.color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.isPaused ? "Resume auto-copy" : "Pause auto-copy")
    }

    private func figure(_ glance: AutoCopyGlance, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PnLText(value: today)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(entry.isPaused ? "Today · paused" : "Today")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(entry.isPaused ? DeskColor.action.color : DeskColor.nightMuted.color)
        }
    }

    private func small(_ glance: AutoCopyGlance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                DeskMark(size: 22)
                Spacer()
                toggle(compact: true)
            }
            Spacer(minLength: 6)
            figure(glance, size: 30)
            Spacer(minLength: 6)
            Text(autoCopyStatus(paused: false, traders: glance.traders, openCopies: glance.openCopies, shadow: glance.isShadow))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DeskColor.nightMuted.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func medium(_ glance: AutoCopyGlance) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                header(glance)
                Spacer(minLength: 6)
                figure(glance, size: 30)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    toggle(compact: false)
                    Text("\(glance.isShadow ? "Shadow · " : "")\(glance.traders == 1 ? "1 trader" : "\(glance.traders) traders")\n\(glance.openCopies) open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: 134, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if glance.moves.isEmpty {
                    Spacer()
                    Text("Waiting for your traders' next move.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Spacer()
                } else {
                    ForEach(glance.moves.prefix(3)) { MoveRow(move: $0) }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rectangular(_ glance: AutoCopyGlance) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(entry.isPaused ? "Auto-Copy Paused" : "Auto-Copy", systemImage: entry.isPaused ? "pause.fill" : "square.on.square")
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
            Text(AutoCopyGlance.money(today) + " today")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .privacySensitive()
            Text("\(glance.openCopies) open · \(glance.traders) traders")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ glance: AutoCopyGlance) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.isPaused ? "pause.fill" : "square.on.square")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                Text(AutoCopyGlance.money(today).replacingOccurrences(of: ".00", with: ""))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .monospacedDigit()
                    .privacySensitive()
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        case .accessoryInline:
            Label("Auto-copy is off", systemImage: "square.on.square")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.on.square").font(.system(size: 18, weight: .semibold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Auto-Copy", systemImage: "square.on.square").font(.system(size: 13, weight: .semibold))
                Text("Pick a trader in Desk").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                DeskMark(size: 24)
                Spacer(minLength: 0)
                Text("Copy the best traders on Perpl")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pick one on Signals")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview(as: .systemMedium) {
    AutoCopyWidget()
} timeline: {
    AutoCopyEntry(date: .now, glance: .preview, isPaused: false)
    AutoCopyEntry(date: .now, glance: .preview, isPaused: true)
}
