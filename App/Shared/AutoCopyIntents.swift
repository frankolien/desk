import ActivityKit
import AppIntents
import WidgetKit

/// Every auto-copy intent runs in Desk's own process, so a pause from the Lock Screen also
/// reaches a copy loop that is running.
enum AutoCopyControl {
    static let controlKind = "com.opia.desk.auto-copy-control"
    static let widgetKind = "com.opia.desk.auto-copy"

    static func set(paused: Bool) async {
        AutoCopySwitch.isPaused = paused
        for activity in Activity<AutoCopyActivityAttributes>.activities {
            var state = activity.content.state
            state.isPaused = paused
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        ControlCenter.shared.reloadControls(ofKind: controlKind)
    }
}

struct SetAutoCopyIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Auto-Copy"
    static let description = IntentDescription("Turns auto-copy on or off.")
    static let isDiscoverable = false

    @Parameter(title: "Running")
    var value: Bool

    init() {}

    init(running: Bool) { value = running }

    func perform() async throws -> some IntentResult {
        await AutoCopyControl.set(paused: !value)
        return .result()
    }
}

struct PauseAutoCopyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Auto-Copy"
    static let description = IntentDescription("Stops Desk copying new trades. Copies already open keep their stops.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AutoCopyControl.set(paused: true)
        return .result(dialog: "Auto-copy is paused. Open copies keep their stop losses.")
    }
}

struct ResumeAutoCopyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Auto-Copy"
    static let description = IntentDescription("Lets Desk copy your traders' next moves again.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AutoCopyControl.set(paused: false)
        let traders = AutoCopyGlance.load()?.traders ?? 0
        return .result(dialog: traders == 0
            ? "Auto-copy is on, but you aren't copying anyone yet."
            : "Auto-copy is back on. Keep Desk open to copy the next move.")
    }
}

struct AutoCopyStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Auto-Copy Status"
    static let description = IntentDescription("How today's copy trades are doing.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let glance = AutoCopyGlance.load(), glance.isSetUp else {
            return .result(dialog: "You aren't copying anyone yet. Pick a trader on Signals to start.")
        }
        let state = AutoCopySwitch.isPaused ? "paused" : "on"
        let pnl = AutoCopyGlance.money(glance.today)
        let open = glance.openCopies == 1 ? "1 copy open" : "\(glance.openCopies) copies open"
        return .result(dialog: "Auto-copy is \(state). \(pnl) today, \(open), copying \(glance.traders == 1 ? "1 trader" : "\(glance.traders) traders").")
    }
}
