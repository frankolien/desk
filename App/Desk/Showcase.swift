import Foundation

/// Every surface is on. The flags stay as names so a screen can still ask, and so one of
/// them can be turned off again in one place if a mainnet test says it must.
enum Showcase {
    static let nadNames = true
    static let spotTrading = true
    static let smartMoney = true
    static let marketChat = true
    static let perplSiteLinks = true
    static let signalsExtras = true
    static let openOrders = true
    static let news = true
}
