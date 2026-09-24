//
//  CheckInComposeView.swift
//  Hackysack
//

import SwiftUI

/// Second step of the checkin flow: write a message for the selected place,
/// choose who can see it, and submit.
struct CheckInComposeView: View {
    let place: Place
    /// Present when the picker skipped the list because it was confident about
    /// `place`. Shows a Change Location button that returns to the ranked list.
    var onChangeLocation: (() -> Void)? = nil
    let onSubmit: (_ message: String?, _ visibility: CheckinVisibility) -> Void

    @State private var message = ""
    @State private var visibility: CheckinVisibility = .everyone
    @FocusState private var isMessageFocused: Bool

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
                    Label("Change Location", systemImage: "mappin.and.ellipse")
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
                // Options for the checkin. More controls will join the toggle here.
                HStack {
                    CheckinPrivacyToggle(visibility: $visibility)
                    Spacer()
                }
                .controlSize(.small)

                Button {
                    onSubmit(message, visibility)
                } label: {
                    Text("Check In")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(.blue)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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

    private var placeDetail: String? {
        let typeName = place.primaryType.map { PlaceTypeSymbol.displayName(for: $0) }
        let parts = [place.address, typeName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack {
        CheckInComposeView(place: .preview) { message, visibility in
            print("Submitted: \(message ?? "<no message>") (\(visibility.rawValue))")
        }
    }
}

#Preview("Suggested") {
    NavigationStack {
        CheckInComposeView(place: .preview, onChangeLocation: { print("Change location") }) { message, visibility in
            print("Submitted: \(message ?? "<no message>") (\(visibility.rawValue))")
        }
    }
}
