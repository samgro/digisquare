//
//  EditProfileView.swift
//  Hackysack
//

import CoreLocation
import PhotosUI
import SwiftUI

/// The profile form, in two roles.
///
/// As `.editing` it is the sheet behind Profile's Edit button. As `.setup` it
/// is the gate RootView shows until the profile has a name and a hometown —
/// which is where every new account lands straight after signup, since none
/// has a hometown yet.
struct EditProfileView: View {
    enum Purpose {
        case editing
        case setup
    }

    let purpose: Purpose

    @Environment(AuthManager.self) private var authManager
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""
    @State private var hometown = ""
    /// What the location prefill put in the hometown field, so the footer can
    /// say where it came from for as long as it is still the value shown.
    @State private var prefilledHometown: String?
    @State private var isLocatingHometown = false

    @State private var isShowingCamera = false
    @State private var isShowingPhotoLibrary = false
    @State private var isShowingFileImporter = false
    @State private var pickedItem: PhotosPickerItem?
    /// Held between the camera closing and the cropper opening: presenting one
    /// full-screen cover while the other is still dismissing is dropped.
    @State private var capturedPhoto: UIImage?
    @State private var imageAwaitingCrop: IdentifiableImage?
    @State private var croppedImage: UIImage?
    @State private var shouldRemoveAvatar = false

    @State private var isSaving = false
    @State private var saveStatus: String?
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var isConfirmingDiscard = false
    @State private var hasLoadedInitialValues = false
    @FocusState private var isNameFocused: Bool

    /// Keeps the three field labels in one column, and grows with Dynamic Type.
    @ScaledMetric private var labelWidth: CGFloat = 92

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

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHometown: String {
        hometown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        guard let profile else { return false }
        return name != (profile.name ?? "")
            || bio != (profile.bio ?? "")
            || hometown != (profile.hometown ?? "")
            || croppedImage != nil
            || shouldRemoveAvatar
    }

    private var isBioOverLimit: Bool {
        bio.count > Self.bioCharacterLimit
    }

    private var hasPhoto: Bool {
        croppedImage != nil || (profile?.avatarURL != nil && !shouldRemoveAvatar)
    }

    private var canSave: Bool {
        // Name and hometown are both required: saving without either would
        // put the user straight back on the setup screen.
        let isComplete = !trimmedName.isEmpty && !trimmedHometown.isEmpty && !isBioOverLimit
        switch purpose {
        case .editing:
            return isComplete && isDirty
        case .setup:
            // Setup always saves, even untouched: the prefilled hometown has
            // never been sent to the server.
            return isComplete
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                aboutSection
                hometownSection

                if let errorMessage {
                    Section {
                        FormErrorBanner(message: errorMessage)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(purpose == .setup ? "Set Up Your Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if purpose == .setup {
                    continueButton
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
            .photosPicker(
                isPresented: $isShowingPhotoLibrary,
                selection: $pickedItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: [.image]) { result in
                loadImportedFile(result)
            }
            .fullScreenCover(isPresented: $isShowingCamera, onDismiss: showCapturedPhoto) {
                CameraPicker(
                    onCapture: { image in
                        capturedPhoto = image
                        isShowingCamera = false
                    },
                    onCancel: { isShowingCamera = false }
                )
                .ignoresSafeArea()
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
            .onAppear(perform: loadInitialValues)
            .task(id: locationManager.authorizationStatus) {
                requestLocationForPrefill()
            }
            .task(id: locationManager.location == nil) {
                await prefillHometownFromLocation()
            }
            .interactiveDismissDisabled(isDirty)
            .disabled(isSaving)
        }
    }

    // MARK: - Sections

    private var avatarSection: some View {
        Section {
            VStack(spacing: HackysackSpacing.small) {
                photoMenu {
                    avatarPreview
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: Glyphs.editPhoto)
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .padding(HackysackSpacing.small)
                                .background(Color.accentColor, in: Circle())
                                .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 3))
                        }
                }

                photoMenu {
                    Text(hasPhoto ? "Edit Photo" : "Add Photo")
                        .font(.subheadline.weight(.semibold))
                }

                if let saveStatus {
                    Text(saveStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if purpose == .setup {
                    Text("Add a photo and your hometown so friends know it's you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, HackysackSpacing.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HackysackSpacing.small)
        }
        .listRowBackground(Color.clear)
    }

    private var aboutSection: some View {
        Section {
            fieldRow("Name", errorMessage: fieldErrors["name"]) {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .focused($isNameFocused)
            }

            fieldRow("Bio", errorMessage: fieldErrors["bio"]) {
                TextField("A line about you", text: $bio, axis: .vertical)
                    .lineLimit(1...5)
            }
        } footer: {
            HStack {
                if trimmedName.isEmpty && fieldErrors["name"] == nil {
                    Text("Your name can't be empty")
                }
                Spacer()
                Text("\(bio.count)/\(Self.bioCharacterLimit)")
                    .monospacedDigit()
                    .foregroundStyle(isBioOverLimit ? .red : .secondary)
            }
        }
    }

    private var hometownSection: some View {
        Section {
            NavigationLink {
                CityPickerView(hometown: $hometown)
            } label: {
                fieldRow("Hometown", errorMessage: fieldErrors["hometown"]) {
                    if !hometown.isEmpty {
                        Label(hometown, systemImage: Glyphs.hometown)
                            .labelStyle(HometownLabelStyle())
                    } else if isLocatingHometown {
                        HStack(spacing: HackysackSpacing.small) {
                            ProgressView()
                            Text("Finding your city…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Choose a city")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } footer: {
            if prefilledHometown != nil && hometown == prefilledHometown {
                Text("Based on your current location. Tap to change it.")
            } else {
                Text("Shown on your profile.")
            }
        }
    }

    /// An inline-labelled row: the label in a fixed column on the left, the
    /// control filling the rest, and a validation message underneath.
    private func fieldRow<Content: View>(
        _ label: String,
        errorMessage: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HackysackSpacing.small / 2) {
            // Top rather than .firstTextBaseline: a vertical-axis TextField
            // (Bio) misreports its baseline, which pushed the field a line
            // below its label. Label and value share a font, so top alignment
            // still lines their text up.
            HStack(alignment: .top, spacing: HackysackSpacing.small) {
                Text(label)
                    .frame(width: labelWidth, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, labelWidth + HackysackSpacing.small)
            }
        }
    }

    // MARK: - Photo

    /// Every photo source, behind whatever label taps it: the avatar itself
    /// and the "Edit Photo" text under it both open the same menu.
    private func photoMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: Glyphs.camera) {
                    isShowingCamera = true
                }
            }
            Button("Choose Photo", systemImage: Glyphs.choosePhoto) {
                isShowingPhotoLibrary = true
            }
            Button("Choose File", systemImage: Glyphs.chooseFile) {
                isShowingFileImporter = true
            }
            if hasPhoto {
                Divider()
                Button("Remove Photo", systemImage: Glyphs.delete, role: .destructive) {
                    croppedImage = nil
                    pickedItem = nil
                    shouldRemoveAvatar = true
                }
            }
        } label: {
            label()
        }
        // Borderless, so each menu in the row gets its own tap rather than
        // the Form treating the whole row as one button.
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let croppedImage {
            Image(uiImage: croppedImage)
                .resizable()
                .scaledToFill()
                .frame(width: HackysackSize.avatarHero, height: HackysackSize.avatarHero)
                .clipShape(Circle())
        } else {
            AvatarView(
                url: shouldRemoveAvatar ? nil : profile?.avatarURL,
                initials: initials,
                size: HackysackSize.avatarHero
            )
        }
    }

    /// Follows the name field as it is typed, so a new user sees their own
    /// initials appear rather than a question mark.
    private var initials: String {
        let letters = trimmedName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if purpose == .editing {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) {
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
                    Button(role: .confirm, action: save)
                        .disabled(!canSave)
                }
            }
        }
        if purpose == .setup {
            ToolbarItem(placement: .topBarLeading) {
                // An escape hatch, so nobody can get stranded on this screen
                // with no way back out.
                Button("Sign Out") {
                    Task { await authManager.signOut() }
                }
            }
        }
    }

    private var continueButton: some View {
        Button(action: save) {
            if isSaving {
                ProgressView().tint(.white)
            } else {
                Text("Continue")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canSave || isSaving)
        .padding(.horizontal, HackysackSpacing.large)
        .padding(.bottom, HackysackSpacing.small)
    }

    // MARK: - Loading

    private func loadInitialValues() {
        guard !hasLoadedInitialValues, let profile else { return }
        name = profile.name ?? ""
        bio = profile.bio ?? ""
        hometown = profile.hometown ?? ""
        hasLoadedInitialValues = true

        // Apple withholds the name after the first authorization, so a
        // returning Apple user can arrive here without one.
        if purpose == .setup && name.isEmpty {
            isNameFocused = true
        }
    }

    /// Setup asks for a single fix to prefill the hometown. Nothing else is
    /// tracking location yet — ContentView starts that once setup is done.
    private func requestLocationForPrefill() {
        guard purpose == .setup, hometown.isEmpty else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            // No prefill; the user searches for their city instead.
            break
        @unknown default:
            break
        }
    }

    private func prefillHometownFromLocation() async {
        guard purpose == .setup, hometown.isEmpty, let location = locationManager.location else { return }
        isLocatingHometown = true
        let city = await CitySearch.cityName(at: location)
        isLocatingHometown = false
        // The user may have picked a city while the lookup was in flight.
        guard let city, hometown.isEmpty else { return }
        hometown = city
        prefilledHometown = city
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
        // Cleared so choosing the same photo again still fires onChange.
        pickedItem = nil
    }

    private func loadImportedFile(_ result: Result<URL, any Error>) {
        errorMessage = nil
        guard case .success(let url) = result else {
            errorMessage = "Couldn't open that file. Try choosing a different one."
            return
        }
        // Files outside the app's sandbox are only readable inside this scope.
        let isAccessingScope = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            errorMessage = "Couldn't open that file as an image. Try choosing a different one."
            return
        }
        imageAwaitingCrop = IdentifiableImage(image: image)
    }

    private func showCapturedPhoto() {
        guard let capturedPhoto else { return }
        imageAwaitingCrop = IdentifiableImage(image: capturedPhoto)
        self.capturedPhoto = nil
    }

    // MARK: - Saving

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        isNameFocused = false

        Task {
            var avatarKey: String?

            // Upload first, so a failed image never costs the user their text
            // edits. If this fails we stop and leave the form open with
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
                    errorMessage = "Couldn't upload photo. Your other changes weren't saved."
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

                let savedProfile = try await authManager.updateProfile(
                    name: .editing(trimmedName),
                    bio: .editing(trimmedBio),
                    avatarKey: avatarUpdate,
                    // Never .editing: canSave guarantees a value, and the API
                    // refuses to clear a hometown.
                    hometown: .value(trimmedHometown)
                )
                switch purpose {
                case .editing:
                    dismiss()
                case .setup:
                    // Normally nothing to do: the saved profile is complete,
                    // so RootView swaps this screen for the app. If the
                    // server accepted the save but dropped a field, say so
                    // rather than leaving Continue looking broken.
                    if savedProfile.isMissingRequiredFields {
                        errorMessage = "Your profile saved without a hometown. Try again in a moment."
                    }
                }
            } catch let error as APIError {
                var collected: [String: String] = [:]
                for field in ["name", "bio", "avatarKey", "hometown"] {
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

/// The pin in the accent color, the city in the primary text color — so the
/// hometown row reads as a filled-in value rather than a tinted link.
private struct HometownLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: HackysackSpacing.small / 2) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

/// The camera, library and file sources all hand back a UIImage, which is
/// not Identifiable, so wrap it for `fullScreenCover(item:)`.
///
/// This is held directly in @State rather than derived through a computed
/// Binding: a wrapper built in the getter would mint a fresh id on every body
/// evaluation, and fullScreenCover(item:) would read that as a new item and
/// re-present the cropper in a loop.
private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview("Editing") {
    EditProfileView(purpose: .editing)
        .environment(AuthManager())
        .environment(LocationManager())
}

#Preview("Setup") {
    EditProfileView(purpose: .setup)
        .environment(AuthManager())
        .environment(LocationManager())
}
