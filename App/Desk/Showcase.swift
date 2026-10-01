import Foundation

/// What the submission build shows. Each flag hides one entry point and leaves its code in
/// place; launching with `-show-everything` brings them all back.
enum Showcase {
    private static let everything = ProcessInfo.processInfo.arguments.contains("-show-everything")

    /// Registration waits on nad.domains.
    static let nadNames = everything
    /// Spot buying, selling, trending tokens and token search.
    static let spotTrading = everything
    static let smartMoney = everything
    static let marketChat = everything
    /// Perpl's key and rescue pages need a wallet connected on Perpl's site.
    static let perplSiteLinks = everything
    /// Signals' Watchlist and Market sections repeat Home and the market page.
    static let signalsExtras = everything
    /// Until stops are read back from Perpl.
    static let openOrders = everything
    static let news = everything
}
