import DeskUI
import SwiftUI
import WebKit

/// A headline read inside Desk: our header over the publisher's own page, so following a
/// story never means leaving the app. The markets it mentions are one tap away.
struct NewsArticleScreen: View {
    let item: NewsItem
    let market: MarketModel
    var onOpenMarket: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failed = false
    @State private var showsSafari = false

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 14)
                story.padding(.horizontal, 20).padding(.top, 16)
                page.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showsSafari) {
            if let link = item.link { InAppSafari(url: link).ignoresSafeArea() }
        }
    }

    private var header: some View {
        HStack {
            circleButton("xmark") { dismiss() }
            Spacer()
            if let link = item.link {
                circleButton("safari") { showsSafari = true }
                ShareLink(item: link, message: Text(item.title)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .deskGlass(interactive: true, in: Circle())
            }
        }
    }

    private var story: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.source) · \(NewsRow.age(of: item.date))")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(item.title)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)
            if !item.symbols.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.symbols.prefix(3), id: \.self) { symbol in
                        let change = market.allMarkets.first { $0.symbol == symbol }.flatMap(market.changePercent(for:))
                        Button { onOpenMarket?(symbol) } label: {
                            HStack(spacing: 5) {
                                Text(symbol).foregroundStyle(DeskColor.nightText.color)
                                if let change {
                                    Text(String(format: "%+.2f%%", change))
                                        .foregroundStyle(change >= 0 ? DeskColor.rise.color : DeskColor.fall.color)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(DeskColor.nightMuted.color)
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(DeskPressStyle())
                        .disabled(onOpenMarket == nil)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var page: some View {
        if let link = item.link, !failed {
            ArticleWebView(url: link, loading: $loading, failed: $failed)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    if loading {
                        ProgressView().tint(.white)
                    }
                }
        } else {
            VStack(spacing: 14) {
                Text("This story couldn't be shown here.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                if item.link != nil {
                    Button { showsSafari = true } label: {
                        Text("Open in Safari")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(DeskPressStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .deskGlass(interactive: true, in: Circle())
    }
}

/// The publisher's page, with the chrome Desk's own. Only the page itself is theirs.
private struct ArticleWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading, failed: $failed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loading: Binding<Bool>
        private var failed: Binding<Bool>

        init(loading: Binding<Bool>, failed: Binding<Bool>) {
            self.loading = loading
            self.failed = failed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading.wrappedValue = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            loading.wrappedValue = false
            failed.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            loading.wrappedValue = false
        }
    }
}
