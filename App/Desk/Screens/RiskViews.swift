import DeskUI
import Foundation
import Observation
import SwiftUI

enum RiskLevel: String, Decodable, Sendable {
    case low, caution, high, unchecked

    var title: String {
        switch self {
        case .low: "Low risk"
        case .caution: "Caution"
        case .high: "High risk"
        case .unchecked: "Not checked"
        }
    }

    var color: Color {
        switch self {
        case .low: DeskColor.rise.color
        case .caution: DeskColor.action.color
        case .high: DeskColor.fall.color
        case .unchecked: DeskColor.nightMuted.color
        }
    }

    var needsAttention: Bool { self == .caution || self == .high }
}

struct TokenRisk: Decodable, Sendable {
    struct Reason: Decodable, Identifiable, Sendable {
        let code: String
        let text: String
        let severity: String
        var id: String { code + text }
    }
    struct Fact: Decodable, Identifiable, Sendable {
        let code: String
        let text: String
        var id: String { code + text }
    }
    let level: RiskLevel
    let reasons: [Reason]
    let facts: [Fact]
    let checkedAt: Double

    /// What a list row can say before the server has looked: the same thresholds the
    /// server uses, on the figures the discovery feed already carries.
    static func quick(riskLevel: String?, liquidity: Double?, communityRecognized: Bool?) -> RiskLevel {
        var weight = 0
        var checked = false
        // OKX's riskLevelControl: 1 is ordinary, 2 elevated, 3 and up flagged.
        if let flag = riskLevel {
            checked = true
            let number = Double(flag) ?? 0
            if flag.lowercased() == "high" || number >= 3 { weight += 6 } else if flag.lowercased() == "medium" || number == 2 { weight += 3 }
        }
        if let liquidity {
            checked = true
            if liquidity < 10_000 { weight += 6 } else if liquidity < 50_000 { weight += 3 }
        }
        if communityRecognized == false { checked = true; weight += 1 }
        guard checked else { return .unchecked }
        return weight >= 6 ? .high : weight >= 3 ? .caution : .low
    }
}

@MainActor
@Observable
final class TokenRiskModel {
    private(set) var risk: TokenRisk?
    private(set) var failed = false

    func load(chainIndex: String, contract: String, riskLevel: String?, communityRecognized: Bool?) async {
        var components = URLComponents(string: "https://web-lovat-nine-49.vercel.app/api/token-details")!
        var items = [
            URLQueryItem(name: "view", value: "risk"),
            URLQueryItem(name: "chainIndex", value: chainIndex),
            URLQueryItem(name: "address", value: contract),
        ]
        if let riskLevel { items.append(URLQueryItem(name: "riskLevel", value: riskLevel)) }
        if let communityRecognized { items.append(URLQueryItem(name: "communityRecognized", value: communityRecognized ? "true" : "false")) }
        components.queryItems = items
        guard let url = components.url else { return }
        do {
            let (data, _) = try await ResponseCache.shared.data(from: url, maxStale: 300)
            risk = try JSONDecoder().decode(TokenRisk.self, from: data)
        } catch {
            failed = true
        }
    }
}

struct RiskChip: View {
    let level: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(level.color).frame(width: 6, height: 6)
            Text(level.title)
                .font(.system(size: compact ? 10 : 11, weight: .bold, design: .rounded))
                .foregroundStyle(level == .unchecked ? DeskColor.nightMuted.color : level.color)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 3 : 6)
        .background(level.color.opacity(level == .unchecked ? 0.08 : 0.14), in: Capsule())
        .accessibilityLabel("Risk: \(level.title)")
    }
}

struct RiskSheet: View {
    let symbol: String
    let risk: TokenRisk?
    let fallback: RiskLevel
    let failed: Bool

    private var level: RiskLevel { risk?.level ?? fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Risk · \(symbol)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                RiskChip(level: level)
            }

            if let risk {
                if risk.reasons.isEmpty {
                    Text("Nothing stood out in the checks below.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 18)
                } else {
                    VStack(spacing: 10) {
                        ForEach(risk.reasons) { reason in
                            line(reason.text, symbol: icon(for: reason.severity), tint: tint(for: reason.severity))
                        }
                    }
                    .padding(.top, 18)
                }
                if !risk.facts.isEmpty {
                    Text("Also true")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.top, 20)
                    VStack(spacing: 8) {
                        ForEach(risk.facts) { fact in
                            line(fact.text, symbol: "checkmark.circle", tint: DeskColor.nightMuted.color)
                        }
                    }
                    .padding(.top, 8)
                }
            } else if failed {
                Text("The checks could not run right now. The figures on the token page still stand.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 18)
            } else {
                SkeletonRow(widthFraction: 0.9).padding(.top, 22)
                SkeletonRow(widthFraction: 0.6).padding(.top, 14)
            }

            Text("A low-risk result does not prove a token is authentic, liquid, sellable, or safe.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
            Text(checkedLine)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color.opacity(0.6))
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.night.color)
    }

    private var checkedLine: String {
        guard let risk else { return "Checking OKX, nad.fun and the chain…" }
        let age = Date.now.timeIntervalSince1970 - risk.checkedAt / 1000
        let when = age < 90 ? "just now" : age < 3600 ? "\(Int(age / 60))m ago" : "\(Int(age / 3600))h ago"
        return "Checked \(when) · OKX, nad.fun, on-chain"
    }

    private func line(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func icon(for severity: String) -> String {
        switch severity {
        case "high": "exclamationmark.octagon.fill"
        case "caution": "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }

    private func tint(for severity: String) -> Color {
        switch severity {
        case "high": DeskColor.fall.color
        case "caution": DeskColor.action.color
        default: DeskColor.nightMuted.color
        }
    }
}

/// The sentence and the warnings above a confirm control. Warnings inform; a single
/// "high" one asks for one acknowledging tap, never a second confirmation.
struct PreSignWarning: Identifiable, Equatable {
    enum Level { case info, caution, high }
    let text: String
    let level: Level
    var id: String { text }
}

struct PreSignPreview: View {
    let sentence: String
    let warnings: [PreSignWarning]
    @Binding var acknowledged: Bool

    private var needsAcknowledgement: Bool { warnings.contains { $0.level == .high } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sentence)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: warning.level == .high ? "exclamationmark.octagon.fill"
                          : warning.level == .caution ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(warning.level == .high ? DeskColor.fall.color
                                         : warning.level == .caution ? DeskColor.action.color : DeskColor.nightMuted.color)
                        .frame(width: 16)
                    Text(warning.text)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if needsAcknowledgement {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { acknowledged.toggle() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: acknowledged ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(acknowledged ? DeskColor.rise.color : DeskColor.nightMuted.color)
                        Text("I understand the risk")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.nightText.color)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskColor.nightChip.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: needsAcknowledgement) { _, needs in if !needs { acknowledged = false } }
    }
}
