import AppIntents
import SwiftUI
import WidgetKit

/// Auto-copy's switch in Control Center, on the Lock Screen and on the Action button.
struct AutoCopyToggle: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AutoCopyControl.controlKind, provider: Provider()) { running in
            ControlWidgetToggle("Auto-Copy", isOn: running, action: SetAutoCopyIntent()) { isOn in
                Label(isOn ? "Copying" : "Paused", systemImage: isOn ? "square.on.square.fill" : "pause.fill")
            }
            .tint(.yellow)
        }
        .displayName("Auto-Copy")
        .description("Pause or resume copying your traders.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }

        func currentValue() async throws -> Bool { !AutoCopySwitch.isPaused }
    }
}
