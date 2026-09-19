import SwiftUI
import WidgetKit

@main
struct DeskWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AutoCopyWidget()
        PortfolioWidget()
        WatchlistWidget()
        AutoCopyLiveActivity()
        AutoCopyToggle()
    }
}
