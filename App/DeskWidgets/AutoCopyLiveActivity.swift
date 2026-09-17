import ActivityKit
import AppIntents
import DeskUI
import SwiftUI
import WidgetKit

struct AutoCopyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AutoCopyActivityAttributes.self) { context in
            AutoCopyLockScreen(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(DeskColor.night.color.opacity(0.92))
                .activitySystemActionForegroundColor(DeskColor.nightText.color)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        DeskMark(size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Auto-Copy")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(state.isPaused ? "Paused" : (context.isStale ? "Open Desk" : (state.isStreaming ? "Live" : "Checking")))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(state.isPaused || context.isStale ? DeskColor.action.color : DeskColor.rise.color)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        PnLText(value: state.today)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("today")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DeskColor.nightMuted.color)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        if let move = state.lastMove {
                            MoveRow(move: move)
                        } else {
                            Text(autoCopyStatus(paused: state.isPaused, traders: state.traders,
                                                openCopies: state.openCopies, shadow: state.isShadow))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DeskColor.nightMuted.color)
                            Spacer()
                        }
                        PauseButton(isPaused: state.isPaused)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                }
            } compactLeading: {
                DeskMark(size: 20)
                    .opacity(state.isPaused ? 0.5 : 1)
            } compactTrailing: {
                if state.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(DeskColor.action.color)
                } else {
                    PnLText(value: state.today)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            } minimal: {
                DeskMark(size: 20)
                    .opacity(state.isPaused ? 0.5 : 1)
            }
            .keylineTint(DeskColor.action.color)
        }
    }
}

struct PauseButton: View {
    let isPaused: Bool

    var body: some View {
        Button(intent: SetAutoCopyIntent(running: isPaused)) {
            Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPaused ? DeskColor.onAction.color : DeskColor.nightText.color)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isPaused ? DeskColor.action.color : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AutoCopyLockScreen: View {
    let state: AutoCopyActivityAttributes.ContentState
    let isStale: Bool

    private var subtitle: String {
        if isStale && !state.isPaused { return "Open Desk to keep copying" }
        return autoCopyStatus(paused: state.isPaused, traders: state.traders, openCopies: state.openCopies, shadow: state.isShadow)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                DeskMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-Copy")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(state.isPaused || isStale ? DeskColor.action.color : DeskColor.nightMuted.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    PnLText(value: state.today)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("today")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            HStack(spacing: 10) {
                if let move = state.lastMove {
                    MoveRow(move: move)
                } else {
                    Text("Waiting for your traders' next move")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DeskColor.nightMuted.color)
                    Spacer()
                }
                PauseButton(isPaused: state.isPaused)
            }
        }
        .padding(16)
    }
}

#Preview("Lock Screen", as: .content, using: AutoCopyActivityAttributes()) {
    AutoCopyLiveActivity()
} contentStates: {
    AutoCopyActivityAttributes.ContentState(today: 14.62, openCopies: 2, traders: 3, isPaused: false, isStreaming: true,
                                            isShadow: false, lastMove: AutoCopyGlance.preview.moves.first)
}
