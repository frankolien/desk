import DeskMoney
import Foundation
import Observation

/// The currency balances and profit are shown in.
///
/// Display only. AUSD is a dollar stablecoin and every order, deposit and withdrawal stays
/// denominated in it; market prices stay in dollars because that is what the venue
/// quotes. What converts is what a person reads to know how they are doing.
@MainActor
@Observable
final class DisplayCurrency {
    struct Option: Identifiable, Hashable {
        let code: String
        let name: String
        let flag: String
        let symbol: String
        var id: String { code }
    }

    static let shared = DisplayCurrency()

    static let options: [Option] = [
        Option(code: "USD", name: "US Dollar", flag: "🇺🇸", symbol: "$"),
        Option(code: "EUR", name: "Euro", flag: "🇪🇺", symbol: "€"),
        Option(code: "GBP", name: "British Pound", flag: "🇬🇧", symbol: "£"),
        Option(code: "NGN", name: "Nigerian Naira", flag: "🇳🇬", symbol: "₦"),
        Option(code: "GHS", name: "Ghanaian Cedi", flag: "🇬🇭", symbol: "₵"),
        Option(code: "KES", name: "Kenyan Shilling", flag: "🇰🇪", symbol: "KSh "),
        Option(code: "ZAR", name: "South African Rand", flag: "🇿🇦", symbol: "R "),
        Option(code: "INR", name: "Indian Rupee", flag: "🇮🇳", symbol: "₹"),
        Option(code: "JPY", name: "Japanese Yen", flag: "🇯🇵", symbol: "¥"),
        Option(code: "CNY", name: "Chinese Yuan", flag: "🇨🇳", symbol: "CN¥"),
        Option(code: "KRW", name: "South Korean Won", flag: "🇰🇷", symbol: "₩"),
        Option(code: "CAD", name: "Canadian Dollar", flag: "🇨🇦", symbol: "CA$"),
        Option(code: "AUD", name: "Australian Dollar", flag: "🇦🇺", symbol: "A$"),
        Option(code: "BRL", name: "Brazilian Real", flag: "🇧🇷", symbol: "R$"),
        Option(code: "MXN", name: "Mexican Peso", flag: "🇲🇽", symbol: "MX$"),
        Option(code: "AED", name: "UAE Dirham", flag: "🇦🇪", symbol: "AED "),
        Option(code: "TRY", name: "Turkish Lira", flag: "🇹🇷", symbol: "₺"),
        Option(code: "CHF", name: "Swiss Franc", flag: "🇨🇭", symbol: "CHF "),
        Option(code: "SGD", name: "Singapore Dollar", flag: "🇸🇬", symbol: "S$"),
    ]

    private static let codeKey = "desk.currency"
    private static let ratesKey = "desk.currencyRates"
    private static let fetchedKey = "desk.currencyRatesFetchedAt"
    private static let endpoint = URL(string: "https://web-lovat-nine-49.vercel.app/api/fx")!

    private(set) var code: String
    /// Dollars to each currency. Kept from the last good fetch so an offline launch still
    /// shows the chosen currency rather than silently falling back to dollars.
    private(set) var rates: [String: Double]
    private var fetchedAt: Date?

    private init() {
        code = UserDefaults.standard.string(forKey: Self.codeKey) ?? "USD"
        rates = UserDefaults.standard.dictionary(forKey: Self.ratesKey) as? [String: Double] ?? ["USD": 1]
        fetchedAt = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date
    }

    var option: Option { Self.options.first { $0.code == code } ?? Self.options[0] }

    /// Dollars convert only once a rate exists; until then figures stay in dollars and say so.
    private var active: (option: Option, rate: Double) {
        if let rate = rates[code] { return (option, rate) }
        return (Self.options[0], 1)
    }

    func select(_ code: String) {
        self.code = code
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 3600 { return }
        guard let (data, response) = try? await URLSession.shared.data(from: Self.endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Rates.self, from: data),
              body.rates["USD"] == 1 else { return }
        rates = body.rates
        fetchedAt = .now
        UserDefaults.standard.set(body.rates, forKey: Self.ratesKey)
        UserDefaults.standard.set(Date.now, forKey: Self.fetchedKey)
    }

    func rate(for code: String) -> Double? { rates[code] }

    /// A dollar amount in the chosen currency: "₦1,702,560.18", "−€42.10".
    func format(_ dollars: Double, signed: Bool = false, compact: Bool = false) -> String {
        let (option, rate) = active
        let value = dollars * rate
        let sign = value < 0 ? "\u{2212}" : (signed && value > 0 ? "+" : "")
        return sign + option.symbol + Self.magnitude(abs(value), code: option.code, compact: compact)
    }

    func format(_ money: Money, signed: Bool = false, compact: Bool = false) -> String {
        format(Double(money.raw) / 1_000_000, signed: signed, compact: compact)
    }

    private static func magnitude(_ value: Double, code: String, compact: Bool) -> String {
        if compact {
            switch value {
            case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
            case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
            case 10_000...: return String(format: "%.0fK", value / 1_000)
            case 1_000...: return String(format: "%.1fK", value / 1_000)
            case 100...: return String(format: "%.0f", value)
            default: break
            }
        }
        return (["JPY", "KRW"].contains(code) ? wholeUnits : cents).string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let cents: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let wholeUnits: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private struct Rates: Decodable { let rates: [String: Double] }
}
