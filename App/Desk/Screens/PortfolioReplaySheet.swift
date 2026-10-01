import AVFoundation
import DeskMoney
import DeskUI
import SwiftUI
import UIKit

struct PortfolioReplaySheet: View {
    private enum PresentationMode {
        case snapshot
        case replay
    }

    private enum ReplayRange: String, CaseIterable, Identifiable {
        case day = "24h"
        case week = "7d"
        case month = "30d"

        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    let points: [EquityLog.Point]
    let currentTotal: Money?
    let currentPnL: Money?
    let displayName: String
    let address: String
    let network: String
    let openPositions: Int
    let closedTrades: [ClosedTrade]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: PresentationMode = .snapshot
    @State private var range: ReplayRange = .day
    @State private var progress = 1.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var playID = UUID()
    @State private var exportProgress: Double?
    @State private var exportedURL: URL?
    @State private var activityItems: [Any] = []
    @State private var presentsShare = false
    @State private var notice: Notice?
    @State private var imageSaver = PortfolioImageSaver()
    @State private var saver = PortfolioVideoSaver()

    private struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    private let playbackDuration = 10.0

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()

                GeometryReader { proxy in
                    let horizontal: CGFloat = 18
                    let availableWidth = proxy.size.width - horizontal * 2
                    let cardWidth = min(availableWidth, (proxy.size.height - 250) * 0.8)
                    let cardHeight = cardWidth * 1.25

                    VStack(spacing: 16) {
                        PortfolioReplayPreview(
                            data: replayData,
                            progress: mode == .snapshot ? 1 : progress,
                            width: cardWidth,
                            height: cardHeight)
                            .frame(maxWidth: .infinity)

                        if mode == .snapshot {
                            snapshotControls
                        } else {
                            replayControls
                        }
                    }
                    .padding(.horizontal, horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            }
            .navigationTitle(mode == .snapshot ? "Share portfolio" : "Portfolio replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(DeskColor.action.color)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: playID) { await play() }
        .onChange(of: range) { _, _ in
            if mode == .replay { restart() }
        }
        .sheet(isPresented: $presentsShare) {
            if !activityItems.isEmpty { PortfolioReplayActivitySheet(items: activityItems) }
        }
        .overlay(alignment: .top) {
            if let notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .padding(.horizontal, 15)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var replayData: PortfolioReplayData {
        let cutoff = Date.now.addingTimeInterval(-range.seconds)
        var allSamples = points
            .sorted { $0.at < $1.at }
            .map {
                PortfolioReplayData.Sample(
                    at: $0.at,
                    dollars: Double($0.raw) / 1_000_000,
                    pnlDollars: $0.pnlRaw.map { Double($0) / 1_000_000 })
            }

        if let currentTotal {
            let now = Date.now
            let current = Double(currentTotal.raw) / 1_000_000
            let pnl = currentPnL.map { Double($0.raw) / 1_000_000 }
            if let last = allSamples.last,
               abs(last.dollars - current) < 0.000_001,
               last.pnlDollars == pnl {
                allSamples[allSamples.count - 1] = .init(at: now, dollars: current, pnlDollars: pnl)
            } else {
                allSamples.append(.init(at: now, dollars: current, pnlDollars: pnl))
            }
        }

        var samples = allSamples.filter { $0.at >= cutoff }
        var rangeLabel = range.rawValue
        if !hasMovement(samples), hasMovement(allSamples) {
            samples = Array(allSamples.suffix(72))
            rangeLabel = "Last activity"
        }

        if samples.isEmpty {
            let current = currentTotal.map { Double($0.raw) / 1_000_000 } ?? 0
            let pnl = currentPnL.map { Double($0.raw) / 1_000_000 }
            samples = [
                .init(at: cutoff, dollars: current, pnlDollars: pnl),
                .init(at: .now, dollars: current, pnlDollars: pnl),
            ]
        } else if samples.count == 1, let only = samples.first {
            samples.insert(.init(at: cutoff, dollars: only.dollars, pnlDollars: only.pnlDollars), at: 0)
        }

        let pnlHistory = samples.compactMap { sample -> PortfolioReplayData.Sample? in
            guard let pnl = sample.pnlDollars else { return nil }
            return .init(at: sample.at, dollars: pnl, pnlDollars: pnl)
        }
        let tradeHistory = realisedTradeHistory
        let usesPnLHistory = !hasValueMovement(samples) && hasValueMovement(pnlHistory)
        let usesTradeHistory = !hasValueMovement(samples) && !usesPnLHistory && hasValueMovement(tradeHistory)
        let chartSamples = usesPnLHistory ? pnlHistory : (usesTradeHistory ? tradeHistory : samples)

        return PortfolioReplayData(
            samples: samples,
            chartSamples: chartSamples,
            displayName: displayName,
            address: address,
            network: network,
            range: usesTradeHistory ? "Last trade" : rangeLabel,
            chartLabel: usesPnLHistory ? "P&L RECORD" : (usesTradeHistory ? "TRADE HISTORY" : "PORTFOLIO RECORD"),
            openPositions: openPositions,
            closedTrades: closedTrades.count,
            currentPnLDollars: currentPnL.map { Double($0.raw) / 1_000_000 },
            currencyCode: DisplayCurrency.shared.code)
    }

    private func hasMovement(_ samples: [PortfolioReplayData.Sample]) -> Bool {
        guard let first = samples.first else { return false }
        return samples.count >= 2 && samples.contains {
            abs($0.dollars - first.dollars) > 0.000_001 || $0.pnlDollars != first.pnlDollars
        }
    }

    private func hasValueMovement(_ samples: [PortfolioReplayData.Sample]) -> Bool {
        guard let first = samples.first else { return false }
        return samples.count >= 2 && samples.contains { abs($0.dollars - first.dollars) > 0.000_001 }
    }

    private var realisedTradeHistory: [PortfolioReplayData.Sample] {
        let trades = closedTrades
            .filter { $0.realisedPnLRaw != nil }
            .sorted { $0.closedAt < $1.closedAt }
        guard let first = trades.first else { return [] }
        var running = 0.0
        var samples = [PortfolioReplayData.Sample(
            at: first.closedAt.addingTimeInterval(-3600), dollars: 0, pnlDollars: 0)]
        for trade in trades {
            running += Double(trade.realisedPnLRaw ?? 0) / 1_000_000
            samples.append(.init(at: trade.closedAt, dollars: running, pnlDollars: running))
        }
        return samples
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                if progress >= 0.999 { restart() } else { isPlaying.toggle(); playID = UUID() }
            } label: {
                Image(systemName: progress >= 0.999 ? "arrow.counterclockwise" : (isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(DeskPressStyle())
            .foregroundStyle(DeskColor.nightText.color)
            .deskGlass(interactive: true, in: Circle())
            .accessibilityLabel(progress >= 0.999 ? "Replay" : (isPlaying ? "Pause" : "Play"))

            Slider(
                value: $progress,
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        isPlaying = false
                        playID = UUID()
                    }
                })
                .tint(DeskColor.action.color)
                .disabled(exportProgress != nil)
                .accessibilityLabel("Portfolio replay timeline")
                .accessibilityValue(replayData.accessibilityValue(at: progress))

            Text("1×")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
        }
    }

    private var rangePicker: some View {
        Picker("Replay range", selection: $range) {
            ForEach(ReplayRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(exportProgress != nil)
    }

    private var snapshotControls: some View {
        VStack(spacing: 12) {
            rangePicker

            Button {
                mode = .replay
                restart()
            } label: {
                Label("Replay portfolio", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(DeskColor.onAction.color)
                    .background(DeskColor.action.color, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(DeskPressStyle(scale: 0.985))

            HStack(spacing: 10) {
                snapshotAction(symbol: "square.and.arrow.down", title: "Save image", action: saveImage)
                snapshotAction(symbol: "square.and.arrow.up", title: "Share", action: shareImage)
                snapshotAction(symbol: "doc.on.doc", title: "Copy image", action: copyImage)
            }
        }
    }

    private var replayControls: some View {
        VStack(spacing: 12) {
            playbackControls
            rangePicker
            HStack(spacing: 10) {
                Button {
                    isPlaying = false
                    playID = UUID()
                    progress = 1
                    mode = .snapshot
                } label: {
                    Label("Image", systemImage: "photo")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 108, height: 52)
                        .foregroundStyle(DeskColor.nightText.color)
                        .contentShape(Capsule())
                }
                .buttonStyle(DeskPressStyle())
                .deskGlass(interactive: true, in: Capsule())
                .disabled(exportProgress != nil)

                exportButton
            }
        }
    }

    private func snapshotAction(
        symbol: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(DeskColor.nightText.color)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(DeskPressStyle())
        .deskGlass(interactive: true, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var exportButton: some View {
        Button(action: exportVideo) {
            HStack(spacing: 10) {
                if let exportProgress {
                    ProgressView(value: exportProgress)
                        .tint(DeskColor.onAction.color)
                        .frame(width: 22)
                    Text("Rendering \(Int(exportProgress * 100))%")
                } else {
                    Image(systemName: "square.and.arrow.down")
                    Text("Save video")
                }
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(DeskColor.onAction.color)
            .background(DeskColor.action.color, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(DeskPressStyle(scale: 0.985))
        .disabled(exportProgress != nil)
    }

    private func restart() {
        progress = 0
        isPlaying = true
        playID = UUID()
    }

    private func play() async {
        guard isPlaying, !isScrubbing else { return }
        if reduceMotion {
            progress = 1
            isPlaying = false
            return
        }
        let start = Date.now.addingTimeInterval(-progress * playbackDuration)
        while !Task.isCancelled, isPlaying, progress < 1 {
            progress = min(1, Date.now.timeIntervalSince(start) / playbackDuration)
            try? await Task.sleep(for: .milliseconds(33))
        }
        if progress >= 1 { isPlaying = false }
    }

    private func exportVideo() {
        isPlaying = false
        playID = UUID()
        exportProgress = 0
        let data = replayData

        Task { @MainActor in
            do {
                let url = try await PortfolioReplayExporter.export(data: data) { rendered in
                    exportProgress = rendered
                }
                exportedURL = url
                exportProgress = nil
                saver.save(url) { saved in
                    showNotice(saved
                        ? Notice(text: "Video saved to Photos", isError: false)
                        : Notice(text: "Couldn’t save — use Share instead", isError: true))
                    if !saved {
                        activityItems = [url]
                        presentsShare = true
                    }
                }
            } catch {
                exportProgress = nil
                showNotice(Notice(text: "Video couldn’t be rendered", isError: true))
            }
        }
    }

    @MainActor
    private func snapshotImage() -> UIImage? {
        let renderer = ImageRenderer(content: PortfolioReplayCard(data: replayData, progress: 1))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private func saveImage() {
        guard let image = snapshotImage() else {
            showNotice(Notice(text: "Image couldn’t be rendered", isError: true))
            return
        }
        imageSaver.save(image) { saved in
            if saved { Haptics.success() } else { Haptics.failure() }
            showNotice(Notice(
                text: saved ? "Image saved to Photos" : "Couldn’t save the image",
                isError: !saved))
        }
    }

    private func shareImage() {
        guard let image = snapshotImage() else {
            showNotice(Notice(text: "Image couldn’t be rendered", isError: true))
            return
        }
        activityItems = [image]
        presentsShare = true
    }

    private func copyImage() {
        guard let image = snapshotImage() else {
            showNotice(Notice(text: "Image couldn’t be rendered", isError: true))
            return
        }
        UIPasteboard.general.image = image
        Haptics.success()
        showNotice(Notice(text: "Image copied", isError: false))
    }

    private func showNotice(_ newNotice: Notice) {
        withAnimation(.snappy) { notice = newNotice }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard notice == newNotice else { return }
            withAnimation(.snappy) { notice = nil }
        }
    }
}

private struct PortfolioReplayData: Sendable {
    struct Sample: Sendable {
        let at: Date
        let dollars: Double
        let pnlDollars: Double?
    }

    let samples: [Sample]
    let chartSamples: [Sample]
    let displayName: String
    let address: String
    let network: String
    let range: String
    let chartLabel: String
    let openPositions: Int
    let closedTrades: Int
    let currentPnLDollars: Double?
    let currencyCode: String

    var first: Double { samples.first?.dollars ?? 0 }
    var last: Double { samples.last?.dollars ?? 0 }
    var change: Double { last - first }
    var changePercent: Double? { first == 0 ? nil : change / first * 100 }

    func value(at progress: Double) -> Double {
        guard samples.count > 1 else { return first }
        let position = max(0, min(1, progress)) * Double(samples.count - 1)
        let lower = min(Int(position), samples.count - 1)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = position - Double(lower)
        return samples[lower].dollars + (samples[upper].dollars - samples[lower].dollars) * fraction
    }

    func date(at progress: Double) -> Date {
        guard let first = samples.first?.at, let last = samples.last?.at else { return .now }
        return first.addingTimeInterval(last.timeIntervalSince(first) * max(0, min(1, progress)))
    }

    func pnl(at progress: Double) -> Double {
        guard samples.count > 1 else { return samples.first?.pnlDollars ?? currentPnLDollars ?? 0 }
        let position = max(0, min(1, progress)) * Double(samples.count - 1)
        let lower = min(Int(position), samples.count - 1)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = position - Double(lower)
        let lowerPnL = samples[lower].pnlDollars
        let upperPnL = samples[upper].pnlDollars
        switch (lowerPnL, upperPnL) {
        case let (lower?, upper?): return lower + (upper - lower) * fraction
        case let (known?, nil), let (nil, known?): return known
        case (nil, nil): return currentPnLDollars ?? 0
        }
    }

    func accessibilityValue(at progress: Double) -> String {
        let value = value(at: progress)
        let pnl = pnl(at: progress)
        return "Portfolio \(value.formatted(.currency(code: "USD"))), total profit and loss \(pnl.formatted(.currency(code: "USD")))"
    }
}

private struct PortfolioReplayPreview: View {
    let data: PortfolioReplayData
    let progress: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        PortfolioReplayCard(data: data, progress: progress)
            .frame(width: PortfolioReplayCard.size.width, height: PortfolioReplayCard.size.height)
            .scaleEffect(width / PortfolioReplayCard.size.width, anchor: .topLeading)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.34), radius: 22, y: 12)
    }
}

private struct PortfolioReplayCard: View {
    static let size = CGSize(width: 1080, height: 1350)

    let data: PortfolioReplayData
    let progress: Double

    private var visibleCount: Int {
        max(2, min(data.chartSamples.count, Int((Double(data.chartSamples.count - 1) * progress).rounded(.up)) + 1))
    }

    private var current: Double { data.value(at: progress) }
    private var currentPnL: Double { data.pnl(at: progress) }
    private var currentDate: Date { data.date(at: progress) }
    private var isUp: Bool { currentPnL >= 0 }
    private var tint: Color { (isUp ? DeskColor.rise : DeskColor.fall).color }

    var body: some View {
        ZStack {
            DeskColor.night.color

            RadialGradient(
                colors: [DeskColor.action.color.opacity(0.24), .clear],
                center: UnitPoint(x: 0.88, y: 0.06), startRadius: 0, endRadius: 650)
            RadialGradient(
                colors: [DeskColor.ledger.color.opacity(0.30), .clear],
                center: UnitPoint(x: 0.12, y: 0.78), startRadius: 0, endRadius: 620)

            VStack(alignment: .leading, spacing: 0) {
                header
                valueBlock.padding(.top, 72)
                PortfolioReplayChart(
                    samples: data.chartSamples,
                    visibleCount: visibleCount,
                    tint: isUp ? DeskColor.rise : DeskColor.fall)
                    .frame(height: 520)
                    .padding(.top, 52)

                Spacer(minLength: 28)
                facts
                footer.padding(.top, 42)
            }
            .padding(72)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay {
            RoundedRectangle(cornerRadius: 52, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [DeskColor.action.color, DeskColor.action.color.opacity(0.18), Color.white.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 52, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            DeskBrandMark(size: 82)
            VStack(alignment: .leading, spacing: 9) {
                Text(data.displayName)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                    .lineLimit(1)
                Text(data.address)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospaced())
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
            Spacer(minLength: 18)
            VStack(alignment: .trailing, spacing: 9) {
                Text(data.range)
                    .font(.system(size: data.range.count > 5 ? 22 : 30, weight: .black, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(data.chartLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(DeskColor.nightMuted.color)
            }
        }
    }

    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PORTFOLIO VALUE")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(format(current))
                .font(.system(size: 78, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text("TOTAL P&L")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 5)
            HStack(spacing: 12) {
                Text(format(currentPnL, signed: true))
            }
            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            Text(currentDate.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 3)
        }
    }

    private var facts: some View {
        HStack(spacing: 0) {
            replayFact("OPEN", "\(data.openPositions)", alignment: .leading)
            divider
            replayFact("CLOSED TRADES", "\(data.closedTrades)", alignment: .center)
            divider
            replayFact("NETWORK", data.network, alignment: .trailing)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.11)).frame(width: 1, height: 66).padding(.horizontal, 30)
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 18) {
                DeskBrandMark(size: 66)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DESK")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .tracking(6)
                    Text("Your trades. Your record.")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
            }
            Spacer()
            Text("trydesk.trade")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.action.color)
        }
        .foregroundStyle(DeskColor.nightText.color)
    }

    private func replayFact(_ label: String, _ value: String, alignment: FactAlignment) -> some View {
        VStack(alignment: alignment.horizontal, spacing: 7) {
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(DeskColor.nightMuted.color)
            Text(value)
                .font(.system(size: 23, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightText.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: alignment.frame)
    }

    private enum FactAlignment {
        case leading
        case center
        case trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var frame: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    private func format(_ dollars: Double, signed: Bool = false) -> String {
        // Replay data is recorded in AUSD; exporting in USD keeps a saved video stable across currency settings.
        let sign = dollars < 0 ? "−" : (signed && dollars > 0 ? "+" : "")
        let absolute = abs(dollars)
        let body: String
        switch absolute {
        case 1_000_000_000...: body = String(format: "$%.2fB", absolute / 1_000_000_000)
        case 1_000_000...: body = String(format: "$%.2fM", absolute / 1_000_000)
        case 10_000...: body = String(format: "$%.1fK", absolute / 1_000)
        default: body = String(format: "$%.2f", absolute)
        }
        return sign + body
    }
}

private struct PortfolioReplayChart: View {
    let samples: [PortfolioReplayData.Sample]
    let visibleCount: Int
    let tint: DeskRGB

    var body: some View {
        Canvas { context, size in
            let all = positions(in: size, samples: samples)
            guard all.count >= 2 else { return }
            let visible = Array(all.prefix(max(2, min(visibleCount, all.count))))

            var grid = Path()
            for row in 0...3 {
                let y = size.height * CGFloat(row) / 3
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Color.white.opacity(0.075)), style: .init(lineWidth: 1, dash: [5, 10]))

            var line = Path()
            line.move(to: visible[0])
            for point in visible.dropFirst() { line.addLine(to: point) }

            var fill = line
            fill.addLine(to: CGPoint(x: visible.last?.x ?? 0, y: size.height))
            fill.addLine(to: CGPoint(x: visible[0].x, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.color.opacity(0.28), tint.color.opacity(0)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint.color), style: .init(lineWidth: 9, lineCap: .round, lineJoin: .round))

            if let last = visible.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 11, y: last.y - 11, width: 22, height: 22)), with: .color(tint.color))
                context.stroke(Path(ellipseIn: CGRect(x: last.x - 17, y: last.y - 17, width: 34, height: 34)), with: .color(tint.color.opacity(0.28)), lineWidth: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private func positions(in size: CGSize, samples: [PortfolioReplayData.Sample]) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let values = samples.map(\.dollars)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.14, max(abs(high), 1) * 0.015)
        let floor = low - padding
        let ceiling = high + padding
        let span = max(ceiling - floor, 0.000_001)
        let firstDate = samples[0].at.timeIntervalSinceReferenceDate
        let lastDate = samples[samples.count - 1].at.timeIntervalSinceReferenceDate
        let duration = max(lastDate - firstDate, 1)

        return samples.map { sample in
            let x = (sample.at.timeIntervalSinceReferenceDate - firstDate) / duration
            let y = (sample.dollars - floor) / span
            return CGPoint(x: size.width * x, y: size.height * (1 - y))
        }
    }
}

@MainActor
private enum PortfolioReplayExporter {
    static let duration = 10.0
    static let framesPerSecond: Int32 = 24

    static func export(
        data: PortfolioReplayData,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-portfolio-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(PortfolioReplayCard.size.width),
            AVVideoHeightKey: Int(PortfolioReplayCard.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 7_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(PortfolioReplayCard.size.width),
                kCVPixelBufferHeightKey as String: Int(PortfolioReplayCard.size.height),
            ])

        guard writer.canAdd(input) else { throw ExportError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotStart }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * Double(framesPerSecond))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            let progress = Double(frame) / Double(max(frameCount - 1, 1))
            let renderer = ImageRenderer(content: PortfolioReplayCard(data: data, progress: progress))
            renderer.scale = 1
            renderer.isOpaque = true
            guard let image = renderer.uiImage,
                  let buffer = pixelBuffer(for: image, pool: adaptor.pixelBufferPool) else {
                throw ExportError.cannotRenderFrame
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? ExportError.cannotAppendFrame
            }
            if frame.isMultiple(of: 4) {
                onProgress(Double(frame + 1) / Double(frameCount))
                await Task.yield()
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.cannotFinish }
        onProgress(1)
        return url
    }

    private static func pixelBuffer(for image: UIImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(
                nil, cgImage.width, cgImage.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: baseAddress,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(cgImage.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return buffer
    }

    private enum ExportError: Error {
        case cannotAddInput
        case cannotStart
        case cannotRenderFrame
        case cannotAppendFrame
        case cannotFinish
    }
}

@MainActor
private final class PortfolioImageSaver: NSObject {
    private var completion: ((Bool) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(
            image, self,
            #selector(finished(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc nonisolated private func finished(
        _ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer
    ) {
        let saved = error == nil
        Task { @MainActor in self.completion?(saved) }
    }
}

@MainActor
private final class PortfolioVideoSaver: NSObject {
    private var completion: ((Bool) -> Void)?

    func save(_ url: URL, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        UISaveVideoAtPathToSavedPhotosAlbum(
            url.path, self,
            #selector(finished(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc nonisolated private func finished(
        _ path: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer
    ) {
        let saved = error == nil
        Task { @MainActor in self.completion?(saved) }
    }
}

private struct PortfolioReplayActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
