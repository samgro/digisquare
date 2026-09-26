//
//  CheckInComposeView.swift
//  Hackysack
//

import PhotosUI
import SwiftUI

/// Second step of the checkin flow: write a message for the selected place,
/// add photos, choose who can see it, and submit.
struct CheckInComposeView: View {
    let place: Place
    /// Present when the picker skipped the list because it was confident about
    /// `place`. Shows a Change Location button that returns to the ranked list.
    var onChangeLocation: (() -> Void)? = nil
    let onSubmit: (_ message: String?, _ visibility: CheckinVisibility, _ photos: [PreparedPhoto]) -> Void

    @State private var message = ""
    @State private var visibility: CheckinVisibility = .friends
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var photos: [PreparedPhoto] = []
    @State private var isPreparingPhotos = false
    @State private var photoError: String?
    @FocusState private var isMessageFocused: Bool

    /// Matches the server's cap on photos per checkin.
    private static let maxPhotoCount = 4
    private static let thumbnailSize: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let placeDetail {
                Text(placeDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if let onChangeLocation {
                Button(action: onChangeLocation) {
                    Label("Change Location", systemImage: Glyphs.changeLocation)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .accessibilityHint("Shows the list of nearby places")
            }

            TextEditor(text: $message)
                .focused($isMessageFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("What's happening here?")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.top, 8)
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if !photos.isEmpty || isPreparingPhotos {
                    photoRow
                }
                if let photoError {
                    Text(photoError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Options for the checkin: who sees it, and its photos.
                HStack {
                    CheckinPrivacyToggle(visibility: $visibility)
                    Spacer()
                    photosPicker
                }
                .controlSize(.small)

                Button {
                    onSubmit(message, visibility, photos)
                } label: {
                    Text("Check In")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(isPreparingPhotos)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .task(id: pickedItems) {
            await preparePickedPhotos()
        }
        .task {
            isMessageFocused = true
            // The push transition can swallow the first focus request; ask again once it settles.
            try? await Task.sleep(for: .milliseconds(400))
            if !isMessageFocused {
                isMessageFocused = true
            }
        }
    }

    private var photosPicker: some View {
        PhotosPicker(
            selection: $pickedItems,
            maxSelectionCount: Self.maxPhotoCount,
            selectionBehavior: .ordered,
            matching: .images
        ) {
            Label(photos.isEmpty ? "Add Photos" : "Edit Photos", systemImage: Glyphs.choosePhoto)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
    }

    private var photoRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    thumbnail(photo, at: index)
                }
                if isPreparingPhotos {
                    ProgressView()
                        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                }
            }
        }
    }

    private func thumbnail(_ photo: PreparedPhoto, at index: Int) -> some View {
        Image(uiImage: UIImage(data: photo.jpegData) ?? UIImage())
            .resizable()
            .scaledToFill()
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: HackysackRadius.compactControl))
            .overlay(alignment: .topTrailing) {
                Button {
                    if pickedItems.indices.contains(index) {
                        pickedItems.remove(at: index)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(2)
                .accessibilityLabel("Remove photo")
            }
    }

    /// Loads, resizes and compresses every picked photo, in the order picked.
    /// Rerun whenever the selection changes; a change mid-way cancels it.
    private func preparePickedPhotos() async {
        guard !pickedItems.isEmpty else {
            photos = []
            photoError = nil
            return
        }
        isPreparingPhotos = true
        defer { isPreparingPhotos = false }

        var prepared: [PreparedPhoto] = []
        var failedCount = 0
        for item in pickedItems {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                failedCount += 1
                continue
            }
            // Resizing a full-size photo is slow enough to stutter the UI.
            let photo = await Task.detached(priority: .userInitiated) {
                UIImage(data: data).flatMap(PreparedPhoto.init(image:))
            }.value
            guard !Task.isCancelled else { return }
            if let photo {
                prepared.append(photo)
            } else {
                failedCount += 1
            }
        }
        photos = prepared
        photoError = failedCount == 0
            ? nil
            : "Couldn't add \(failedCount == 1 ? "a photo" : "\(failedCount) photos"). Try choosing a different one."
    }

    private var placeDetail: String? {
        let typeName = place.categoryName ?? place.primaryType.map { PlaceTypeSymbol.displayName(for: $0) }
        let parts = [place.address, typeName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack {
        CheckInComposeView(place: .preview) { message, visibility, photos in
            print("Submitted: \(message ?? "<no message>") (\(visibility.rawValue)) with \(photos.count) photos")
        }
    }
}

#Preview("Suggested") {
    NavigationStack {
        CheckInComposeView(place: .preview, onChangeLocation: { print("Change location") }) { message, visibility, photos in
            print("Submitted: \(message ?? "<no message>") (\(visibility.rawValue)) with \(photos.count) photos")
        }
    }
}
