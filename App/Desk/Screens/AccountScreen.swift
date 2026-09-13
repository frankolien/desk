import DeskUI
import SwiftUI

/// Where the product's main idea becomes visible.
struct AccountScreen: View {
    let model: AppModel

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 12) {
                    ValueRow(label: "Address", value: model.addressShort)
                    ValueRow(label: "Collateral", value: "\(model.collateral.value?.display() ?? "—") AUSD")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Trading key")
                        .font(DeskType.title)
                        .foregroundStyle(DeskColor.nightText.color)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DeskColor.nightLine.color)
                            Capsule().fill(DeskColor.action.color)
                                .frame(width: geometry.size.width * model.sessionFraction)
                        }
                    }
                    .frame(height: 6)

                    Text("\(model.sessionRemaining.clockText) remaining")
                        .font(DeskType.value)
                        .foregroundStyle(DeskColor.nightText.color)
                    Text("Derived from your face. Never stored, never written to disk.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)

                    Button("End session now") {
                        Task { await model.endSession() }
                    }
                    .font(DeskType.label)
                    .foregroundStyle(DeskColor.fall.color)
                    .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Withdraw")
                        .font(DeskType.title)
                        .foregroundStyle(DeskColor.nightText.color)
                    // The sentence that explains why a stolen API key cannot take the
                    // money. It belongs on the screen, not in a write-up.
                    Text("Withdrawals are signed by your face, not by the trading key. That is why a stolen key cannot move your money.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                    PrimaryButton(title: "Withdraw") {}
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }
}
