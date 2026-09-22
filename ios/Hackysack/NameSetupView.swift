//
//  NameSetupView.swift
//  Hackysack
//

import SwiftUI

/// Collects a display name when Apple did not give us one.
///
/// Apple returns fullName only on the very first authorization for an Apple
/// ID. Anyone who reinstalls, or who signed in before we persisted it, arrives
/// with no name at all — so this screen has to exist.
struct NameSetupView: View {
    @Environment(AuthManager.self) private var authManager

    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: HackysackSpacing.large) {
                Spacer()

                VStack(spacing: HackysackSpacing.small) {
                    Text("What should we call you?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("This is how you'll appear to friends.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    FormErrorBanner(message: errorMessage)
                }

                AuthField(label: nil, text: $name, focusBinding: $isNameFocused)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit(submit)

                Button(action: submit) {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isValid || isSaving)

                Spacer()
            }
            .padding(.horizontal, HackysackSpacing.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // An escape hatch, so nobody can get stranded on this
                    // screen with no way back out.
                    Button("Sign out") {
                        Task { await authManager.signOut() }
                    }
                    .font(.footnote)
                }
            }
            .onAppear { isNameFocused = true }
        }
    }

    private func submit() {
        guard isValid, !isSaving else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await authManager.updateProfile(
                    name: .value(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                    // Untouched on this screen — .unchanged omits them, where
                    // nil would have cleared whatever is already there.
                    bio: .unchanged,
                    avatarKey: .unchanged
                )
            } catch {
                errorMessage = (error as? APIError)?.errorDescription
                    ?? error.localizedDescription
            }
            isSaving = false
        }
    }
}

#Preview {
    NameSetupView()
        .environment(AuthManager())
}
