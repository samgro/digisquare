//
//  CheckInComposeView.swift
//  Digisquare
//

import SwiftUI

/// Second step of the check-in flow: write a message for the selected place and submit.
struct CheckInComposeView: View {
    let place: Place
    let onSubmit: (String?) -> Void

    @State private var message = ""
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let placeDetail {
                Text(placeDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
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
            Button {
                onSubmit(message)
            } label: {
                Text("Check In")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(.blue)
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
        let typeName = place.primaryType.map(PlaceTypeSymbol.displayName)
        let parts = [place.address, typeName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack {
        CheckInComposeView(place: .preview) { message in
            print("Submitted: \(message ?? "<no message>")")
        }
    }
}
