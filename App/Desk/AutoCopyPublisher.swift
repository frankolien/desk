import ActivityKit
import AppIntents
import Foundation
import UIKit
import WidgetKit

/// Keeps auto-copy's widget and Live Activity in step with the copy loop.
///
/// The loop only runs while Desk is open, so the Live Activity carries a short stale date:
/// once Desk is closed it stops claiming to copy and asks to be opened instead.
@MainActor
final class AutoCopyPublisher {
    static let liveActivityKey = "desk.copy.liveActivity"

    static var showsLiveActivity: Bool {
        get { UserDefaults.standard.object(forKey: liveActivityKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: liveActivityKey) }
    }

    private var lastGlance: AutoCopyGlance?
    private var lastState: AutoCopyActivityAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var lastSignature: Signature?
    private var lastPublished = Date.distantPast
    private var lastRequest = Date.distantPast

    private static let staleAfter: TimeInterval = 90
    /// How long a request that ActivityKit refused waits before being tried again. Without
    /// it the copy loop's tick retries five times a second, forever.
    private static let requestBackoff: TimeInterval = 60

    /// What the glance is derived from, cheap enough to compute on every tick.
    private struct Signature: Equatable {
        let entries: Int
        let newest: UUID?
        let open: Int
        let traders: Int
        let paused: Bool
        let streaming: Bool
        let marks: Double
    }

    func follow(_ copier: CopyTrader) {
        // The log and the figures are only worth rebuilding when something moved. A heartbeat
        // still runs every ten seconds, which is what keeps the Live Activity's stale date
        // ahead of the clock.
        let signature = Signature(
            entries: copier.log.count, newest: copier.log.first?.id, open: copier.open.count,
            traders: copier.traders.count, paused: copier.isPaused, streaming: copier.isStreaming,
            marks: copier.open.compactMap(\.lastMark).reduce(0, +))
        guard signature != lastSignature || Date.now.timeIntervalSince(lastPublished) > 10 else { return }
        lastSignature = signature
        lastPublished = .now

        let glance = Self.glance(of: copier)
        var comparable = glance
        comparable.updatedAt = lastGlance?.updatedAt ?? glance.updatedAt
        if comparable != lastGlance || !Calendar.current.isDateInToday(lastGlance?.updatedAt ?? .distantPast) {
            lastGlance = glance
            glance.save()
            WidgetCenter.shared.reloadTimelines(ofKind: AutoCopyControl.widgetKind)
        }
        updateActivity(glance: glance, copier: copier)
    }

    private func updateActivity(glance: AutoCopyGlance, copier: CopyTrader) {
        let activities = Activity<AutoCopyActivityAttributes>.activities
        guard glance.isSetUp, Self.showsLiveActivity, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !activities.isEmpty {
                lastState = nil
                Task { await Self.endAll() }
            }
            return
        }
        let state = AutoCopyActivityAttributes.ContentState(
            today: glance.today, openCopies: glance.openCopies, traders: glance.traders,
            isPaused: copier.isPaused, isStreaming: copier.isStreaming, isShadow: glance.isShadow,
            lastMove: glance.moves.first)
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter))

        if activities.isEmpty {
            // ActivityKit refuses for reasons that do not clear immediately — the system limit,
            // a focus mode, the user turning activities off — so a refusal waits rather than
            // being retried on the next tick.
            guard UIApplication.shared.applicationState == .active,
                  Date.now.timeIntervalSince(lastRequest) > Self.requestBackoff else { return }
            lastRequest = .now
            guard (try? Activity.request(attributes: AutoCopyActivityAttributes(), content: content)) != nil else { return }
            lastState = state
            lastPush = .now
            return
        }
        // A heartbeat keeps the stale date ahead while Desk is open.
        guard state != lastState || Date.now.timeIntervalSince(lastPush) > Self.staleAfter / 3 else { return }
        lastState = state
        lastPush = .now
        Task { await Self.updateAll(content) }
    }

    private nonisolated static func endAll() async {
        for activity in Activity<AutoCopyActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func updateAll(_ content: ActivityContent<AutoCopyActivityAttributes.ContentState>) async {
        for activity in Activity<AutoCopyActivityAttributes>.activities { await activity.update(content) }
    }

    private static func glance(of copier: CopyTrader) -> AutoCopyGlance {
        let live = copier.figures(shadow: false)
        let shadow = copier.figures(shadow: true)
        let closed = live.closed + shadow.closed
        let rate: Double? = closed == 0 ? nil
            : ((live.winRate ?? 0) * Double(live.closed) + (shadow.winRate ?? 0) * Double(shadow.closed)) / Double(closed)
        let moves = copier.log.lazy
            .filter { $0.kind == .opened || (($0.kind == .closed || $0.kind == .protected) && $0.pnl != nil) }
            .prefix(3)
            .map { entry in
                AutoCopyGlance.Move(
                    id: entry.id, date: entry.date, trader: CopyTrader.name(for: entry.trader), symbol: entry.symbol,
                    isLong: entry.isLong, kind: entry.kind == .opened ? .opened : .closed,
                    leverage: entry.leverage, pnl: entry.pnl)
            }
        return AutoCopyGlance(
            traders: copier.traders.count, openCopies: copier.open.count, today: copier.realisedToday,
            realised: live.realised + shadow.realised, closedTrades: closed, winRate: rate,
            isShadow: !copier.traders.isEmpty && copier.traders.allSatisfy { $0.rules.mode == .shadow },
            moves: Array(moves), updatedAt: .now)
    }
}

struct DeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseAutoCopyIntent(),
            phrases: ["Pause auto-copy in \(.applicationName)", "Stop copying in \(.applicationName)",
                      "Pause \(.applicationName) copy trading"],
            shortTitle: "Pause Auto-Copy", systemImageName: "pause.fill")
        AppShortcut(
            intent: ResumeAutoCopyIntent(),
            phrases: ["Resume auto-copy in \(.applicationName)", "Start copying in \(.applicationName)",
                      "Resume \(.applicationName) copy trading"],
            shortTitle: "Resume Auto-Copy", systemImageName: "play.fill")
        AppShortcut(
            intent: AutoCopyStatusIntent(),
            phrases: ["How is my copy trading in \(.applicationName)", "\(.applicationName) copy status",
                      "How much did \(.applicationName) make today"],
            shortTitle: "Copy Status", systemImageName: "chart.line.uptrend.xyaxis")
    }
}
