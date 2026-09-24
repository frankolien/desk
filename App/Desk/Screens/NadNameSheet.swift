import DeskAuth
import DeskChain
import DeskFlow
import DeskUI
import PhotosUI
import SwiftUI

/// A wallet's .nad identity: the names it holds, one to find, and the records on each.
struct NadNameSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var names = NadNamesModel()
    @State private var findsName: String?
    @State private var profileFor: NadNameStatus?

    private var address: String { model.address?.checksummed ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                DeskBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        section("YOUR NAMES") {
                            if !names.loaded {
                                placeholder
                            } else if names.names.isEmpty {
                                row(icon: "at", title: "No .nad name yet", subtitle: "One-time fee, yours for life, paid in MON.")
                            } else {
                                ForEach(names.names) { name in
                                    NavigationLink {
                                        NadNameDetail(name: name, model: model, names: names)
                                    } label: {
                                        row(icon: "at", title: name.name, subtitle: name.isPrimary ? "Primary name" : "Tap to set as primary or edit records",
                                            trailing: name.isPrimary ? "Primary" : nil)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        section("ACTIONS") {
                            NavigationLink {
                                NadFindNameView(model: model, names: names)
                            } label: {
                                row(icon: "magnifyingglass", title: "Find a name", subtitle: "Search available .nad names")
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Your primary name is what Desk and other Monad apps show for this wallet.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Nad name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose).fontWeight(.semibold) } }
            .navigationDestination(item: $findsName) { typed in
                NadFindNameView(model: model, names: names, initial: typed)
            }
            .navigationDestination(item: $profileFor) { status in
                NadProfileStep(status: status, model: model, names: names)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: address) { if !address.isEmpty { await names.load(address: address) } }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-nad-find"), arguments.indices.contains(index + 1) { findsName = arguments[index + 1] }
            if let index = arguments.firstIndex(of: "-nad-profile"), arguments.indices.contains(index + 1) {
                await names.check(arguments[index + 1])
                profileFor = names.status
            }
        }
        #endif
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)).frame(height: 58)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func row(icon: String, title: String, subtitle: String, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
                Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.rise.color)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(DeskColor.rise.color.opacity(0.14), in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(DeskColor.nightMuted.color)
        }
        .padding(.horizontal, 10)
        .frame(height: 60)
        .contentShape(Rectangle())
    }
}

/// Type a label, see at once whether it is free and what it costs.
/// The name flow as the first screen after a new sign-in: the same three steps, each
/// with Skip in the corner, ending on Home either way.
struct NadOnboardingScreen: View {
    let model: AppModel
    let onFinish: () -> Void
    @State private var names = NadNamesModel()

    var body: some View {
        NavigationStack {
            NadFindNameView(model: model, names: names, onSkip: onFinish)
                .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

struct NadFindNameView: View {
    let model: AppModel
    let names: NadNamesModel
    var initial = ""
    /// Set when the flow is onboarding: Skip leaves for Home from any step.
    var onSkip: (() -> Void)? = nil

    @State private var typed = ""
    @State private var checking: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var label: String { typed.trimmingCharacters(in: .whitespaces).lowercased() }
    private var valid: Bool { NadNamesModel.isValidLabel(label) }
    private var status: NadNameStatus? { names.status?.label == label ? names.status : nil }
    private var tint: Color {
        guard !label.isEmpty else { return Color.white.opacity(0.2) }
        guard valid, let status else { return valid ? Color.white.opacity(0.35) : DeskColor.fall.color }
        return status.available ? DeskColor.rise.color : DeskColor.fall.color
    }

    var body: some View {
        ZStack(alignment: .top) {
            DeskBackground()
            DeskAurora(height: 420).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                Text("Find your name")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Text("Search available .nad names")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(DeskColor.nightMuted.color)
                    .padding(.top, 6)

                HStack(spacing: 6) {
                    TextField("yourname", text: $typed)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focused)
                        .fixedSize()
                        .frame(minWidth: 40)
                    Text(".nad")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color.opacity(0.7))
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(Color.white.opacity(0.06), in: Capsule())
                .overlay(TravellingBorder(tint: tint))
                .background {
                    // A soft pool of the same light behind the field, so the page is not flat black.
                    Capsule().fill(tint.opacity(0.22)).blur(radius: 46).padding(-14)
                }
                .padding(.top, 34)
                .animation(.snappy(duration: 0.25), value: tint)

                Group {
                    if let status, status.available {
                        Text("\(Self.mon(status.priceMON)) MON one-time" + (status.priceUSDC.map { " · ≈ \($0) USDC" } ?? ""))
                    } else if let problem = names.checkProblem {
                        Text(problem)
                    } else if !label.isEmpty, !valid {
                        Text("Letters, digits and hyphens, up to 32")
                    } else {
                        Text(" ")
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(DeskColor.nightMuted.color)
                .padding(.top, 16)

                Spacer()

                HStack {
                    statusChip
                    Spacer()
                    NavigationLink {
                        if let status { NadProfileStep(status: status, model: model, names: names, onSkip: onSkip) }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Continue")
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(status?.available == true ? DeskColor.rise.color : DeskColor.nightMuted.color)
                        .padding(.horizontal, 18).frame(height: 46)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .deskGlass(interactive: true, in: Capsule())
                    .disabled(status?.available != true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let onSkip {
                ToolbarItem(placement: .confirmationAction) { Button("Skip", action: onSkip).fontWeight(.semibold) }
            }
        }
        .onAppear {
            focused = true
            names.clearCheck()
            if typed.isEmpty, !initial.isEmpty { typed = initial }
        }
        .onChange(of: typed) { _, _ in
            checking?.cancel()
            let label = self.label
            checking = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await names.check(label)
            }
        }
    }

    private var statusChip: some View {
        let (text, colour, symbol): (String, Color, String) = {
            if label.isEmpty { return ("Enter a name", DeskColor.nightMuted.color, "textformat") }
            if !valid { return ("Invalid", DeskColor.fall.color, "xmark.circle.fill") }
            if names.isChecking || status == nil { return ("Checking…", DeskColor.nightMuted.color, "hourglass") }
            if status?.reserved == true { return ("Reserved", DeskColor.action.color, "lock.fill") }
            return status?.available == true ? ("Available", DeskColor.rise.color, "checkmark.circle.fill") : ("Taken", DeskColor.fall.color, "xmark.circle.fill")
        }()
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            Text(text)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(colour)
        .padding(.horizontal, 14).frame(height: 40)
        .deskGlass(in: Capsule())
    }

    static func mon(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Optional profile on the new name: the picture Desk already has, a line, an X handle, a site.
struct NadProfileStep: View {
    let status: NadNameStatus
    let model: AppModel
    let names: NadNamesModel
    var onSkip: (() -> Void)? = nil

    @State private var useDeskPicture = true
    @State private var bio = ""
    @State private var x = ""
    @State private var website = ""
    @State private var picked: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var hostedAvatar: String?
    @State private var isUploading = false
    @State private var problem: String?
    @State private var goesToConfirm = false

    private var deskAvatar: String? {
        guard let address = model.address?.checksummed else { return nil }
        let identity = IdentityDirectory.shared.identity(for: address)
        return identity?.source == "desk" ? identity?.avatar : nil
    }

    private var records: [String: String] {
        var out: [String: String] = [:]
        if let hostedAvatar { out["avatar"] = hostedAvatar }
        else if useDeskPicture, let deskAvatar { out["avatar"] = deskAvatar }
        if !bio.isEmpty { out["description"] = bio }
        if !x.isEmpty { out["com.twitter"] = x.replacingOccurrences(of: "@", with: "") }
        if !website.isEmpty { out["url"] = website }
        return out
    }

    /// A chosen photo is hosted through the Desk profile first, so the record can point
    /// at a URL. One Face ID; the same picture then shows on Desk too.
    private func continueToConfirm() async {
        if let image, hostedAvatar == nil {
            isUploading = true
            problem = nil
            defer { isUploading = false }
            do {
                let currentName = IdentityDirectory.shared.identity(for: model.address?.checksummed ?? "")
                hostedAvatar = try await model.saveProfile(
                    name: currentName?.source == "desk" ? (currentName?.name ?? "") : "",
                    image: ProfileEditorSheet.jpeg(image))
            } catch PasskeyFailure.cancelledByUser {
                return
            } catch {
                problem = "The picture could not be uploaded. Continue without it or try again."
                return
            }
        }
        goesToConfirm = true
    }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                            ZStack(alignment: .bottomTrailing) {
                                if let image {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
                                } else if useDeskPicture, deskAvatar != nil {
                                    TraderAvatar(address: model.address?.checksummed ?? "", size: 72)
                                } else {
                                    AddressAvatar(address: model.address?.checksummed ?? "", size: 72)
                                }
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DeskColor.night.color)
                                    .frame(width: 24, height: 24)
                                    .background(DeskColor.nightText.color, in: Circle())
                                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add a photo")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.name).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
                            Text(image != nil ? "New photo · hosted by Desk" : "Public profile · optional")
                                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                            if image != nil {
                                Button("Remove photo") { withAnimation(.snappy(duration: 0.2)) { image = nil; picked = nil; hostedAvatar = nil } }
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(DeskColor.nightMuted.color)
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 10)

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if deskAvatar != nil, image == nil {
                        Toggle(isOn: $useDeskPicture) {
                            Text("Use my Desk picture as the avatar")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                        }
                        .tint(DeskColor.rise.color)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("PROFILE DETAILS").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(DeskColor.nightMuted.color).padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            field("Bio", prompt: "Add a short bio", text: $bio)
                            Divider().overlay(Color.white.opacity(0.08))
                            field("X", prompt: "@username", text: $x)
                            Divider().overlay(Color.white.opacity(0.08))
                            field("Website", prompt: "yoursite.com", text: $website, keyboard: .URL)
                        }
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Text("Written to the name on Monad. You can change these any time.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DeskColor.nightMuted.color)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: isUploading ? "Uploading photo…" : "Continue", isEnabled: !isUploading) { Task { await continueToConfirm() } }
                .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let loaded = UIImage(data: data) else { return }
                withAnimation(.snappy(duration: 0.2)) { image = ProfileEditorSheet.squared(loaded); hostedAvatar = nil }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // Onboarding's Skip leaves the flow; the sheet's skips the optional profile.
                Button("Skip") { if let onSkip { onSkip() } else { goesToConfirm = true } }.fontWeight(.semibold)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $goesToConfirm) {
            NadConfirmView(status: status, records: records, model: model, names: names, onSkip: onSkip)
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
            Spacer()
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(DeskColor.nightMuted.color))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .frame(height: 50)
    }
}

/// Name, cost, payment, what it sets. Then one Face ID.
struct NadConfirmView: View {
    let status: NadNameStatus
    let records: [String: String]
    let model: AppModel
    let names: NadNamesModel
    var onSkip: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .idle
    private enum Phase: Equatable { case idle, requesting, signing, sending, done(String), failed(String) }

    private var price: NativeAmount? { status.priceWei }
    /// The price plus room for the gas of a heavy registration.
    private var needed: NativeAmount? {
        guard let price, let reserve = NativeAmount(decimalText: "1") else { return nil }
        return NativeAmount(raw: price.raw + reserve.raw)
    }
    private var held: NativeAmount? { model.mainnetMON.value }
    private var shortfall: NativeAmount? {
        guard let needed, let held, held < needed else { return nil }
        return NativeAmount(raw: needed.raw - held.raw)
    }
    private var isBusy: Bool { phase == .requesting || phase == .signing || phase == .sending }
    private var isDone: Bool { if case .done = phase { true } else { false } }

    var body: some View {
        ZStack {
            DeskBackground()
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .done(let hash): done(hash)
                default: details
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle("Confirm registration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let onSkip, !isBusy, !isDone {
                ToolbarItem(placement: .confirmationAction) { Button("Skip", action: onSkip).fontWeight(.semibold) }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .task { await model.refreshMainnetMON() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                row("Name", status.name)
                Divider().overlay(Color.white.opacity(0.08))
                row("One-time cost", "\(NadFindNameView.mon(status.priceMON)) MON")
                Divider().overlay(Color.white.opacity(0.08))
                row("Payment", "MON on Monad, plus gas")
                if !records.isEmpty {
                    Divider().overlay(Color.white.opacity(0.08))
                    row("Records", records.keys.sorted().joined(separator: ", "))
                }
            }
            .padding(.horizontal, 14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Label("Sets this as your primary name", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.rise.color)

            if let shortfall {
                Label("Not enough MON for this name. You need about \(needed?.display(fractionDigits: 0) ?? "") MON and this wallet has \(held?.display(fractionDigits: 2) ?? "0"). Send \(shortfall.display(fractionDigits: 0)) more MON to cover it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let reason) = phase {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(phase == .requesting ? "Asking nad to sign…" : phase == .signing ? "Confirm with Face ID…" : "Registering on Monad…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightMuted.color)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
            }
            HoldToConfirm(title: "Hold to register \(status.name)", tint: DeskColor.action, isEnabled: shortfall == nil && !isBusy && held != nil) {
                Task { await register() }
            }
            .padding(.bottom, 12)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(DeskColor.nightText.color)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 50)
    }

    private func done(_ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            DeskBrandMark(size: 56)
            Text("\(status.name) is yours")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
            Text("Set as your primary name on Monad. Desk shows it everywhere from now.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
            Link(destination: DeskNetwork.mainnet.explorer.appending(path: "tx/\(hash)")) {
                Label("View on explorer", systemImage: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.action.color)
            }
            Spacer()
            PrimaryButton(title: "Done") { if let onSkip { onSkip() } else { dismiss() } }.padding(.bottom, 12)
        }
    }

    private func register() async {
        guard let owner = model.address?.checksummed, let price else { return }
        phase = .requesting
        do {
            let call = try await names.registration(label: status.label, owner: owner, attributes: records)
            let quoted = call.priceMON.flatMap { NativeAmount(decimalText: $0) } ?? price
            phase = .signing
            let hash = try await model.sendNadCall(call, value: quoted)
            phase = .done(hash)
            await names.load(address: owner)
        } catch NadNamesModel.Failure.notOpen {
            phase = .failed("Registering through Desk isn't open yet: nad's signing endpoint is pending. Nothing was charged.")
        } catch NadNamesModel.Failure.refused(let reason) {
            phase = .failed(reason)
        } catch PasskeyFailure.cancelledByUser {
            phase = .idle
        } catch let failure as PasskeyFailure {
            phase = .failed(failure.sentence)
        } catch TransactionSender.Failure.reverted {
            phase = .failed("Monad rejected the registration. Only gas was spent.")
        } catch {
            phase = .failed("The registration could not be sent. Nothing was charged.")
        }
    }
}

/// A name the wallet already holds: its records, and making it the primary.
struct NadNameDetail: View {
    let name: NadName
    let model: AppModel
    let names: NadNamesModel

    @State private var avatar = ""
    @State private var bio = ""
    @State private var x = ""
    @State private var website = ""
    @State private var picked: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var working: String?
    @State private var problem: String?
    @State private var savedAt: Date?

    private var owner: String { model.address?.checksummed ?? "" }
    private var deskAvatar: String? {
        let identity = IdentityDirectory.shared.identity(for: owner)
        return identity?.source == "desk" ? identity?.avatar : nil
    }
    private var changed: [String: String] {
        var out: [String: String] = [:]
        if image != nil { out["avatar"] = "pending" }
        else if avatar != (name.records["avatar"] ?? "") { out["avatar"] = avatar }
        if bio != (name.records["description"] ?? "") { out["description"] = bio }
        if x != (name.records["com.twitter"] ?? "") { out["com.twitter"] = x.replacingOccurrences(of: "@", with: "") }
        if website != (name.records["url"] ?? "") { out["url"] = website }
        return out
    }

    var body: some View {
        ZStack {
            DeskBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                            ZStack(alignment: .bottomTrailing) {
                                if let image {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
                                } else if let url = URL(string: avatar), !avatar.isEmpty {
                                    RemoteImage(url: url, fill: true) { AddressAvatar(address: owner, size: 64) }
                                        .frame(width: 64, height: 64).clipShape(Circle())
                                } else {
                                    AddressAvatar(address: owner, size: 64)
                                }
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DeskColor.night.color)
                                    .frame(width: 22, height: 22)
                                    .background(DeskColor.nightText.color, in: Circle())
                                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose a photo")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name.name).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
                            Text(name.isPrimary ? "Primary name" : "Not primary").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightMuted.color)
                        }
                    }
                    .padding(.top, 10)

                    if !name.isPrimary {
                        Button { Task { await setPrimary() } } label: {
                            Text(working == "primary" ? "Setting…" : "Set as primary name")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(DeskColor.nightText.color)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .deskGlass(interactive: true, in: Capsule())
                        .disabled(working != nil)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECORDS").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(DeskColor.nightMuted.color).padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            HStack {
                                Text("Avatar").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
                                Spacer()
                                if image != nil {
                                    Button("Remove new photo") { image = nil; picked = nil }
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(DeskColor.nightMuted.color)
                                        .buttonStyle(.plain)
                                } else if let deskAvatar, avatar != deskAvatar {
                                    Button("Use my Desk picture") { avatar = deskAvatar }
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(DeskColor.action.color)
                                        .buttonStyle(.plain)
                                } else {
                                    Text(avatar.isEmpty ? "None" : "Set")
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(DeskColor.nightMuted.color)
                                }
                            }
                            .frame(height: 50)
                            Divider().overlay(Color.white.opacity(0.08))
                            field("Bio", prompt: "Add a short bio", text: $bio)
                            Divider().overlay(Color.white.opacity(0.08))
                            field("X", prompt: "@username", text: $x)
                            Divider().overlay(Color.white.opacity(0.08))
                            field("Website", prompt: "yoursite.com", text: $website, keyboard: .URL)
                        }
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(DeskColor.fall.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: savedAt != nil ? "Saved" : (working == "records" ? "Saving…" : "Save records"), isEnabled: !changed.isEmpty && working == nil) {
                Task { await saveRecords() }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .navigationTitle(name.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let loaded = UIImage(data: data) else { return }
                withAnimation(.snappy(duration: 0.2)) { image = ProfileEditorSheet.squared(loaded) }
            }
        }
        .onAppear {
            avatar = name.records["avatar"] ?? ""
            bio = name.records["description"] ?? ""
            x = name.records["com.twitter"] ?? ""
            website = name.records["url"] ?? ""
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(DeskColor.nightText.color)
            Spacer()
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(DeskColor.nightMuted.color))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightText.color)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .frame(height: 50)
    }

    private func saveRecords() async {
        working = "records"; problem = nil
        defer { working = nil }
        do {
            var records = changed
            // A new photo is hosted through the Desk profile first, then the record points at it.
            if let image {
                let identity = IdentityDirectory.shared.identity(for: owner)
                guard let hosted = try await model.saveProfile(
                    name: identity?.source == "desk" ? (identity?.name ?? "") : "", image: ProfileEditorSheet.jpeg(image)) else {
                    problem = "The picture could not be uploaded."; return
                }
                records["avatar"] = hosted
                avatar = hosted
                self.image = nil
            }
            let call = try await names.calldata(["kind": "records", "name": name.label, "records": records])
            _ = try await model.sendNadCall(call, value: .zero)
            savedAt = .now
            await names.load(address: owner)
        } catch { problem = Self.sentence(for: error) }
    }

    private func setPrimary() async {
        working = "primary"; problem = nil
        defer { working = nil }
        do {
            let call = try await names.calldata(["kind": "primary", "name": name.label, "address": owner])
            _ = try await model.sendNadCall(call, value: .zero)
            await names.load(address: owner)
        } catch { problem = Self.sentence(for: error) }
    }

    static func sentence(for error: any Error) -> String? {
        switch error {
        case PasskeyFailure.cancelledByUser: return nil
        case let failure as PasskeyFailure: return failure.sentence
        case NadNamesModel.Failure.refused(let reason): return reason
        case TransactionSender.Failure.reverted: return "Monad rejected the change. Only gas was spent."
        default: return "The change could not be sent. Check your connection and MON for gas."
        }
    }
}


/// A point of light circling the capsule's edge over a faint rim, the way a search field
/// says it is alive. Still with Reduce Motion: the rim alone, in the same tint.
private struct TravellingBorder: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule().stroke(tint.opacity(0.35), lineWidth: 1.2)
            if !reduceMotion {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                    Capsule()
                        .stroke(
                            AngularGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.62),
                                    .init(color: tint.opacity(0.9), location: 0.86),
                                    .init(color: .white, location: 0.97),
                                    .init(color: .clear, location: 1),
                                ],
                                center: .center,
                                angle: .degrees(turn * 360)),
                            lineWidth: 1.8)
                        .blur(radius: 0.3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
