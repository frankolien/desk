import DeskUI
import SwiftUI

/// The currency balances and profit are shown in. Trading stays in AUSD, and the sheet
/// says so, so nobody expects to deposit naira.
struct CurrencySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let currency = DisplayCurrency.shared

    private var options: [DisplayCurrency.Option] {
        guard !query.isEmpty else { return DisplayCurrency.options }
        return DisplayCurrency.options.filter {
            $0.code.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            GlassPage {
                GlassSection(footer: (currency.ratesUnavailable ? "Exchange rates couldn't be reached, so balances stay in US dollars until they can. " : "") + "Balances and profit are shown in this currency. Orders, deposits and withdrawals stay in AUSD, and market prices stay in dollars.") {
                    ForEach(options) { option in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            currency.select(option.code)
                        } label: {
                            HStack(spacing: 10) {
                                Text(option.flag).font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.name).fontWeight(.medium)
                                    Text(sample(option)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(option.code).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(DeskColor.rise.color)
                                    .opacity(currency.code == option.code ? 1 : 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search currencies")
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .task { await currency.refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private func sample(_ option: DisplayCurrency.Option) -> String {
        guard let rate = currency.rate(for: option.code) else {
            return currency.ratesUnavailable ? "Rate unavailable right now" : "Rate loading…"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = rate >= 100 ? 2 : 4
        formatter.minimumFractionDigits = 2
        return "1 AUSD ≈ \(option.symbol)\(formatter.string(from: NSNumber(value: rate)) ?? "\(rate)")"
    }
}
