//
//  SignUpView.swift
//  Hackysack
//

import SwiftUI

struct SignUpView: View {
    @Environment(AuthManager.self) private var authManager
    @Binding var path: [AuthRoute]

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]

    /// Mirrors the server's z.string().min(10), so the user is told the rule
    /// rather than discovering it by being rejected.
    private static let minimumPasswordLength = 10

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && email.contains("@")
            && password.count >= Self.minimumPasswordLength
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HackysackSpacing.large) {
                Text("Create your account")
                    .font(.title.bold())

                if let errorMessage {
                    FormErrorBanner(message: errorMessage)
                }

                AuthField(label: "Name", text: $name, errorMessage: fieldErrors["name"])
                    .textContentType(.name)

                AuthField(label: "Email", text: $email, errorMessage: fieldErrors["email"])
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                VStack(alignment: .leading, spacing: HackysackSpacing.small / 2) {
                    AuthField(
                        label: "Password",
                        text: $password,
                        isSecure: true,
                        errorMessage: fieldErrors["password"]
                    )
                    // .newPassword is what prompts iOS to offer a strong
                    // password and save it to the keychain.
                    .textContentType(.newPassword)

                    if fieldErrors["password"] == nil {
                        Text("At least \(Self.minimumPasswordLength) characters")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Create Account")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isFormValid || isSubmitting)
            }
            .padding(.horizontal, HackysackSpacing.large)
            .padding(.top, HackysackSpacing.large)
        }
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSubmitting)
    }

    private func submit() {
        guard isFormValid, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        fieldErrors = [:]

        Task {
            do {
                try await authManager.register(email: email, password: password, name: name)
            } catch let error as APIError {
                // A 400 from zod carries per-field messages, so put each one
                // under the field it belongs to instead of in the banner.
                var collected: [String: String] = [:]
                for field in ["name", "email", "password"] {
                    if let message = error.message(forField: field) {
                        collected[field] = message
                    }
                }
                fieldErrors = collected
                // Anything without a field — a 409 duplicate email, a 429 —
                // reads as a sentence at the top.
                errorMessage = collected.isEmpty ? error.errorDescription : nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

#Preview {
    NavigationStack {
        SignUpView(path: .constant([]))
            .environment(AuthManager())
    }
}
