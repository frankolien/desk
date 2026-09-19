#if DEBUG
import DeskUI
import SwiftUI
import WidgetKit

/// Every Home Screen widget at every size, drawn inside the app.
///
/// A widget extension cannot be launched from a script and the simulator's Home Screen
/// cannot be edited from one, so without this the only way to see a widget rendered is
/// by hand. `-widget-gallery` on the launch line shows this instead of the app.
struct WidgetGallery: View {
    /// `-widget-gallery watchlist` shows one section, so each fits a single capture.
    private var section: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-widget-gallery"), index + 1 < arguments.count else { return "" }
        return arguments[index + 1]
    }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section != "watchlist" {
                        caption("Portfolio")
                        HStack(spacing: 14) {
                            tile(.systemSmall) { PortfolioWidgetView(glance: .preview, family: .systemSmall) }
                            tile(.systemSmall) { PortfolioWidgetView(glance: nil, family: .systemSmall) }
                        }
                        tile(.systemMedium) { PortfolioWidgetView(glance: .preview, family: .systemMedium) }
                        tile(.systemLarge) { PortfolioWidgetView(glance: .preview, family: .systemLarge) }
                    }
                    if section != "portfolio" {
                        caption("Watchlist")
                        tile(.systemMedium) { WatchlistWidgetView(glance: .preview, family: .systemMedium) }
                        tile(.systemLarge) { WatchlistWidgetView(glance: .preview, family: .systemLarge) }
                        tile(.systemMedium) { WatchlistWidgetView(glance: nil, family: .systemMedium) }
                    }
                }
                .padding(20)
                .padding(.top, 40)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(DeskColor.nightMuted.color)
    }

    /// The 6.1-inch sizes, with WidgetKit's sixteen-point content margin.
    private func tile<Content: View>(_ family: WidgetFamily, @ViewBuilder content: () -> Content) -> some View {
        let size: CGSize = switch family {
        case .systemSmall: CGSize(width: 158, height: 158)
        case .systemLarge: CGSize(width: 338, height: 354)
        default: CGSize(width: 338, height: 158)
        }
        return content()
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(DeskColor.night.color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}
#endif
