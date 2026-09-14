import DeskAuth
import DeskUI
import SwiftUI

/// Where the product's main idea becomes visible.
///
/// The key section shows a state, not a countdown. There used to be a fifteen-minute
/// window here, and when it ran out the app signed the person out — mid-trade included.
/// The trading key cannot move money, so a timer on it was friction with nothing behind
/// it. What the screen now promises is what actually happens: the key lives in memory
/// while Desk is open, and it is wiped when Desk has been away for a moment or the phone
/// locks.
struct AccountScreen: View {
    let model: AppModel
    @State private var showsWithdraw = false

    private var graceSeconds: Int64 { SigningSession.backgroundGrace.components.seconds }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 12) {
                    ValueRow(label: "Address", value: model.addressShort)
                    ValueRow(label: "Collateral", value: "\(model.collateral.value?.display() ?? "—") AUSD")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Trading key")
                            .font(DeskType.title)
                            .foregroundStyle(DeskColor.nightText.color)
                        Spacer()
                        Label(model.isKeyUnlocked ? "Unlocked" : "Locked",
                              systemImage: model.isKeyUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(DeskType.label)
                            .foregroundStyle((model.isKeyUnlocked ? DeskColor.rise : DeskColor.nightMuted).color)
                            .contentTransition(.symbolEffect(.replace))
                    }

                    Text("Derived from your face and held in memory only while Desk is open. "
                         + "Wiped \(graceSeconds) seconds after you leave Desk, and the moment "
                         + "your phone locks. Never written to disk.")
                        .font(DeskType.caption)
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .fixedSize(horizontal: false, vertical: true)

                    if let problem = model.unlockProblem {
                        Text(problem)
                            .font(DeskType.caption)
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 20) {
                        if model.isKeyUnlocked {
                            Button("Lock now") { Task { await model.lock() } }
                                .foregroundStyle(DeskColor.action.color)
                        } else {
                            Button("Unlock with Face ID") { Task { await model.unlock() } }
                                .foregroundStyle(DeskColor.identity.color)
                        }
                        Button("Sign out") { Task { await model.endSession() } }
                            .foregroundStyle(DeskColor.fall.color)
                    }
                    .font(DeskType.label)
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
                    PrimaryButton(title: "Withdraw") { showsWithdraw = true }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .animation(.snappy, value: model.isKeyUnlocked)
        }
        .sheet(isPresented: $showsWithdraw) {
            WithdrawSheet(model: model) { showsWithdraw = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
