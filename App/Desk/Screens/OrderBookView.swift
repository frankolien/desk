import DeskPerpl
import DeskUI
import SwiftUI

/// The selected market's book, bids beside asks, with each row's bar showing the size
/// resting up to that price.
struct OrderBookView: View {
    let market: MarketModel
    var depth = 10

    private var listed: Market? { market.market }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let listed, market.book.isReady {
                summary(listed)
                book(listed)
            } else {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { index in SkeletonRow(widthFraction: 0.9 - Double(index % 3) * 0.12) }
                }
                .padding(.top, 6)
            }
        }
        .animation(.easeOut(duration: 0.12), value: market.book)
    }

    private func summary(_ listed: Market) -> some View {
        HStack(spacing: 14) {
            if let spread = market.book.spreadRaw, let bid = market.book.bestBid, let ask = market.book.bestAsk {
                let mid = Double(bid + ask) / 2
                label("Spread", price(listed, spread) + String(format: " · %.3f%%", mid > 0 ? Double(spread) / mid * 100 : 0))
                Spacer(minLength: 8)
                label("Mid", price(listed, Int64(mid.rounded())))
            } else {
                label("Spread", "—")
                Spacer(minLength: 8)
            }
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(DeskColor.nightMuted.color)
            Text(value).foregroundStyle(DeskColor.nightText.color)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
    }

    private func book(_ listed: Market) -> some View {
        let bids = market.book.levels(.bid, depth: depth)
        let asks = market.book.levels(.ask, depth: depth)
        let bidDepth = running(bids)
        let askDepth = running(asks)
        let most = max(bidDepth.last ?? 0, askDepth.last ?? 0, 1)
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                heading("Size", "Bid", alignment: .leading)
                heading("Ask", "Size", alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 2) {
                    ForEach(Array(bids.enumerated()), id: \.element.id) { index, level in
                        row(size: size(listed, level.sizeRaw), price: price(listed, level.priceRaw),
                            share: Double(bidDepth[index]) / Double(most), side: .bid)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(Array(asks.enumerated()), id: \.element.id) { index, level in
                        row(size: size(listed, level.sizeRaw), price: price(listed, level.priceRaw),
                            share: Double(askDepth[index]) / Double(most), side: .ask)
                    }
                }
            }
        }
    }

    private func heading(_ left: String, _ right: String, alignment: HorizontalAlignment) -> some View {
        HStack {
            Text(left)
            Spacer(minLength: 4)
            Text(right)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(DeskColor.nightMuted.color)
        .frame(maxWidth: .infinity)
    }

    /// Bids read size then price, toward the spread; asks read price then size, away from it.
    private func row(size: String, price: String, share: Double, side: OrderBook.Side) -> some View {
        let tint = (side == .bid ? DeskColor.rise : DeskColor.fall).color
        return HStack {
            Text(side == .bid ? size : price)
                .foregroundStyle(side == .bid ? DeskColor.nightText.color : tint)
            Spacer(minLength: 4)
            Text(side == .bid ? price : size)
                .foregroundStyle(side == .bid ? tint : DeskColor.nightText.color)
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(alignment: side == .bid ? .trailing : .leading) {
            GeometryReader { proxy in
                tint.opacity(0.14)
                    .frame(width: proxy.size.width * min(max(share, 0), 1))
                    .frame(maxWidth: .infinity, alignment: side == .bid ? .trailing : .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func running(_ levels: [OrderBook.Level]) -> [Int64] {
        var total: Int64 = 0
        return levels.map { total += $0.sizeRaw; return total }
    }

    private func price(_ listed: Market, _ raw: Int64) -> String {
        listed.price(raw)?.display(fractionDigits: listed.config.priceDecimals) ?? "—"
    }

    private func size(_ listed: Market, _ raw: Int64) -> String {
        guard let size = listed.size(raw) else { return "—" }
        return size.display(fractionDigits: min(size.decimals, 4))
    }
}
