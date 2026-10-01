import Foundation

/// Each flag hides one entry point and keeps its code; `-show-everything` brings them all back.
enum Showcase {
    private static let everything = ProcessInfo.processInfo.arguments.contains("-show-everything")

    static let nadNames = everything
    static let spotTrading = everything
    static let smartMoney = everything
    static let marketChat = everything
    static let perplSiteLinks = everything
    static let signalsExtras = everything
    static let openOrders = everything
    static let news = everything
}
