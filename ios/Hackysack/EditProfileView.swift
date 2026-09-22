//
//  EditProfileView.swift
//  Hackysack
//

import PhotosUI
import SwiftUI

struct EditProfileView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var imageAwaitingCrop: IdentifiableImage?
    @State private var croppedImage: UIImage?
    @State private var shouldRemoveAvatar = false

    @State private var isSaving = false
    @State private var saveStatus: String?
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var isConfirmingDiscard = false
    @State private var hasLoadedInitialValues = false

    /// Matches the server's z.string().max(160).
    private static let bioCharacterLimit = 160

    private var profile: UserProfile? {
        switch authManager.state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile
        case .launching, .signedOut:
            return nil
        }
    }

    private var isDirty: Bool {
        guard let profile else { return false }
        return name != (profile.name ?? "")
            || bio != (profile.bio ?? "")
            || croppedImage != nil
            || shouldRemoveAvatar
    }

    private var isBioOverLimit: Bool {
        bio.count > Self.bioCharacterLimit
    }

    private var isNameEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        // An empty name is allowed by the API but not meaningful here: saving
        // it would clear the name and drop the user back onto NameSetupView.
        isDirty && !isBioOverLimit && !isNameEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                avatarSection

                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                    if let message = fieldErrors["name"] {
                        Text(message).font(.caption).foregroundStyle(.red)
                    } else if isNameEmpty {
                        Text("Your name can't be empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("A line about you", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                    if let message = fieldErrors["bio"] {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Bio")
                } footer: {
                    Text("\(bio.count)/\(Self.bioCharacterLimit)")
                        .foregroundStyle(isBioOverLimit ? .red : .secondary)
                }

                if let errorMessage {
                    Section {
                        FormErrorBanner(message: errorMessage)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog(
                "Discard your changes?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .fullScreenCover(item: $imageAwaitingCrop) { wrapper in
                AvatarCropView(
                    image: wrapper.image,
                    onCancel: { imageAwaitingCrop = nil },
                    onChoose: { cropped in
                        croppedImage = cropped
                        shouldRemoveAvatar = false
                        imageAwaitingCrop = nil
                    }
                )
            }
            .onChange(of: pickedItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedImage(newItem) }
            }
            .onAppear {
                guard !hasLoadedInitialValues, let profile else { return }
                name = profile.name ?? ""
                bio = profile.bio ?? ""
                hasLoadedInitialValues = true
            }
            .disabled(isSaving)
        }
    }

    private var avatarSection: some View {
        Section {
            VStack(spacing: HackysackSpacing.medium) {
                PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                    avatarPreview
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(HackysackSpacing.small)
                                .background(Color.accentColor, in: Circle())
                        }
                }
                .buttonStyle(.plain)

                if croppedImage != nil || (profile?.avatarURL != nil && !shouldRemoveAvatar) {
                    Button("Remove Photo", role: .destructive) {
                        croppedImage = nil
                        pickedItem = nil
                        shouldRemoveAvatar = true
                    }
                    .font(.footnote)
                }

                if let saveStatus {
                    Text(saveStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HackysackSpacing.medium)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let croppedImage {
            Image(uiImage: croppedImage)
                .resizable()
                .scaledToFill()
                .frame(width: HackysackSize.avatarLarge, height: HackysackSize.avatarLarge)
                .clipShape(Circle())
        } else {
            AvatarView(
                url: shouldRemoveAvatar ? nil : profile?.avatarURL,
                initials: profile?.initials ?? "?",
                size: HackysackSize.avatarLarge
            )
        }
    }

    private func loadPickedImage(_ item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Couldn't load that photo. Try choosing a different one."
                return
            }
            imageAwaitingCrop = IdentifiableImage(image: image)
        } catch {
            errorMessage = "Couldn't load that photo. Try choosing a different one."
        }
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]

        Task {
            var avatarKey: String?

            // Upload first, so a failed image never costs the user their text
            // edits. If this fails we stop and leave the sheet open with
            // everything still filled in.
            if let croppedImage {
                saveStatus = "Uploading photo…"
                do {
                    guard let jpegData = Self.compressedJPEG(from: croppedImage) else {
                        throw APIError.invalidResponse
                    }
                    avatarKey = try await authManager.uploadAvatar(jpegData)
                } catch {
                    saveStatus = nil
                    isSaving = false
                    errorMessage = "Couldn't upload photo. Your name and bio weren't saved."
                    return
                }
            }

            saveStatus = "Saving…"
            do {
                let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

                // The avatar is the one field with three possible outcomes:
                // cleared, replaced, or left exactly as it was.
                let avatarUpdate: ProfileFieldUpdate
                if shouldRemoveAvatar {
                    avatarUpdate = .clear
                } else if let avatarKey {
                    avatarUpdate = .value(avatarKey)
                } else {
                    avatarUpdate = .unchanged
                }

                try await authManager.updateProfile(
                    name: .editing(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                    bio: .editing(trimmedBio),
                    avatarKey: avatarUpdate
                )
                dismiss()
            } catch let error as APIError {
                var collected: [String: String] = [:]
                for field in ["name", "bio", "avatarKey"] {
                    if let message = error.message(forField: field) {
                        collected[field] = message
                    }
                }
                fieldErrors = collected
                errorMessage = collected.isEmpty ? error.errorDescription : nil
            } catch {
                errorMessage = error.localizedDescription
            }
            saveStatus = nil
            isSaving = false
        }
    }

    /// Targets well under the server's 2 MB cap. A 512x512 photo at quality
    /// 0.8 is normally 40-90 KB; the fallbacks exist for pathological images.
    private static func compressedJPEG(from image: UIImage) -> Data? {
        for quality in [0.8, 0.6, 0.4] {
            guard let data = image.jpegData(compressionQuality: quality) else { continue }
            if data.count <= 2_000_000 {
                return data
            }
        }
        return nil
    }
}

/// PhotosPicker hands back a UIImage, which is not Identifiable, so wrap it
/// for `fullScreenCover(item:)`.
///
/// This is held directly in @State rather than derived through a computed
/// Binding: a wrapper built in the getter would mint a fresh id on every body
/// evaluation, and fullScreenCover(item:) would read that as a new item and
/// re-present the cropper in a loop.
private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview {
    EditProfileView()
        .environment(AuthManager())
}
