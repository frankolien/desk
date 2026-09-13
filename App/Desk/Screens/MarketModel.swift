import DeskFlow
import DeskMoney
import DeskPerpl
import DeskUI
import Foundation
import Observation

/// Live market state for one market.
///
/// Everything it exposes goes through `LastGood`, so a dropped poll shows the last figure
/// with its age rather than a zero. The freshness the screen renders is computed from
/// when we received a value, never from the server's own clock.
@MainActor
@Observable
final class MarketModel {
    private(set) var symbol = "BTC"
    private(set) var mark = LastGood<Price>()
    private(set) var market: Market?
    private(set) var isLoadingFirstValue = true
    /// Marks this device has actually seen, oldest first. The venue publishes no candle
    /// endpoint, so this is the only honest series available.
    private(set) var history: [Double] = []

    private static let historyLimit = 90

    private let rest: PerplREST
    private let marketID: UInt32
    private var poller: Task<Void, Never>?

    init(marketID: UInt32 = 16) {
        self.marketID = marketID
        rest = PerplREST(configuration: try! .testnet())
    }

    /// Green while the series is up over its own window, red while it is down. Direction,
    /// not decoration.
    var trend: DeskRGB {
        guard let first = history.first, let last = history.last, last != first else {
            return DeskColor.nightMuted
        }
        return last >= first ? DeskColor.rise : DeskColor.fall
    }

    var changeText: String? {
        guard let first = history.first, let last = history.last, first > 0, history.count >= 2
        else { return nil }
        let percent = (last - first) / first * 100
        let sign = percent < 0 ? Direction.minus : "+"
        return "\(sign)\(String(format: "%.2f", abs(percent)))% while open"
    }

    var freshness: Freshness {
        mark.freshness(socketIsConnected: mark.consecutiveFailures == 0)
    }

    var markText: String {
        guard let price = mark.value, let market else { return "—" }
        return price.display(fractionDigits: market.config.priceDecimals)
    }

    /// The percentage alone. A row has no width for "while open", and a truncated
    /// sentence beside a price reads as a broken figure rather than an elided one.
    var changePercentText: String? {
        guard let first = history.first, let last = history.last, first > 0, history.count >= 2
        else { return nil }
        let percent = (last - first) / first * 100
        let sign = percent < 0 ? Direction.minus : "+"
        return "\(sign)\(String(format: "%.2f", abs(percent)))%"
    }

    var ageText: String? {
        guard let age = mark.age(), freshness != .live else { return nil }
        let seconds = Int(age.components.seconds)
        return seconds < 60 ? "Updated \(seconds)s ago" : "Updated \(seconds / 60)m ago"
    }

    var problemText: String? {
        // Silent for the first couple of failures. A spinner over a number that is still
        // correct is worse than no spinner.
        guard mark.shouldReportProblem() else { return nil }
        return "Reconnecting…"
    }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let delay = self?.mark.retryDelay(), let self else { return }
                try? await Task.sleep(for: delay == .zero ? .seconds(2) : delay)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    /// Seeds from the one previous mark the context carries, so the line exists on the
    /// first poll rather than after the second.
    private func record(market: Market, price: Price) {
        let scale = pow(10.0, Double(market.config.priceDecimals))
        if history.isEmpty, market.state.previousRaw > 0 {
            history.append(Double(market.state.previousRaw) / scale)
        }
        let value = Double(price.raw) / scale
        guard history.last != value else { return }
        history.append(value)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    private func refresh() async {
        do {
            let context = try await rest.context()
            guard let market = context.market(id: marketID),
                  let price = market.price(market.state.markRaw)
            else {
                mark.recordFailure("market \(marketID) is not in the context")
                return
            }
            self.market = market
            symbol = market.symbol
            mark.record(price, serverTimestampMilliseconds: market.state.observedAt.timestampMilliseconds)
            record(market: market, price: price)
            isLoadingFirstValue = false
        } catch {
            mark.recordFailure(String(describing: error))
            isLoadingFirstValue = false
        }
    }
}
