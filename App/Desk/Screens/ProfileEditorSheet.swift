import DeskAuth
import DeskUI
import PhotosUI
import SwiftUI

/// The name and picture other traders see beside this wallet.
struct ProfileEditorSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var name = ""
    @State private var picked: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var removesPicture = false
    @State private var isSaving = false
    @State private var problem: String?
    @State private var saved = false

    private var address: String { model.address?.checksummed ?? "" }
    private var current: Identity? { IdentityDirectory.shared.identity(for: address) }
    private var canSave: Bool {
        !isSaving && (image != nil || removesPicture || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Your profile")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DeskColor.nightText.color)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isSaving)
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                    ZStack(alignment: .bottomTrailing) {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 84, height: 84)
                                .clipShape(Circle())
                        } else if removesPicture {
                            AddressAvatar(address: address, size: 84)
                        } else {
                            TraderAvatar(address: address, size: 84)
                        }
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DeskColor.night.color)
                            .frame(width: 26, height: 26)
                            .background(DeskColor.nightText.color, in: Circle())
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose a picture")

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColor.nightText.color)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: name) { _, value in if value.count > 24 { name = String(value.prefix(24)) } }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .deskGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(TraderSnapshot.short(address))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DeskColor.nightMuted.color)
                        .padding(.leading, 4)
                }
            }

            if image != nil || (current?.avatar != nil && !removesPicture) {
                Button(image != nil ? "Use the current picture instead" : "Remove picture") {
                    withAnimation(.snappy(duration: 0.2)) {
                        if image != nil { image = nil; picked = nil } else { removesPicture = true }
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }

            Label("Signed by your wallet key with Face ID, so only you can set it.", systemImage: "faceid")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DeskColor.nightMuted.color)
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DeskColor.fall.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryButton(title: saved ? "Saved" : (isSaving ? "Saving…" : "Save profile"), isEnabled: canSave) {
                Task { await save() }
            }
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .fittedSheet()
        .presentationDragIndicator(.visible)
        .onAppear { name = current?.source == "desk" ? (current?.name ?? "") : "" }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let loaded = UIImage(data: data) else { return }
                withAnimation(.snappy(duration: 0.2)) { image = Self.squared(loaded); removesPicture = false }
            }
        }
    }

    /// A 256-point square crop, centred, small enough to travel in a request.
    static func squared(_ source: UIImage) -> UIImage {
        let side: CGFloat = 256
        let scale = max(side / source.size.width, side / source.size.height)
        let drawn = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let origin = CGPoint(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(origin: origin, size: drawn))
        }
    }

    /// JPEG under about 60 KB: quality steps down until it fits.
    static func jpeg(_ image: UIImage) -> Data? {
        for quality in [0.82, 0.7, 0.55, 0.4] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 60_000 { return data }
        }
        return image.jpegData(compressionQuality: 0.3)
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        problem = nil
        defer { isSaving = false }
        let picture: Data? = removesPicture ? Data() : image.flatMap(Self.jpeg)
        do {
            try await model.saveProfile(name: name.trimmingCharacters(in: .whitespaces), image: picture)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { saved = true }
            try? await Task.sleep(for: .milliseconds(700))
            onClose()
        } catch PasskeyFailure.cancelledByUser {
            return
        } catch let failure as PasskeyFailure {
            problem = failure.sentence
        } catch DeskProfile.Failure.refused(let reason) {
            problem = reason
        } catch {
            problem = "The profile could not be saved. Check your connection."
        }
    }
}
