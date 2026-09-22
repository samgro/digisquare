//
//  SignInView.swift
//  Hackysack
//

import SwiftUI

struct SignInView: View {
    @Environment(AuthManager.self) private var authManager
    @Binding var path: [AuthRoute]

    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var retryAvailableAt: Date?

    private var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private var isRateLimited: Bool {
        guard let retryAvailableAt else { return false }
        return retryAvailableAt > Date()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HackysackSpacing.large) {
                Text("Welcome back")
                    .font(.title.bold())

                if let errorMessage {
                    FormErrorBanner(message: errorMessage)
                }

                AuthField(label: "Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                AuthField(label: "Password", text: $password, isSecure: true)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(submit)

                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else if let retryAvailableAt, isRateLimited {
                        Text("Try again in \(Text(timerInterval: Date()...retryAvailableAt))")
                    } else {
                        Text("Sign In")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isFormValid || isSubmitting || isRateLimited)

                // No "Forgot password?" link on purpose: there is no reset
                // flow yet, so the link would lead nowhere.

                HStack(spacing: HackysackSpacing.small / 2) {
                    Text("Don't have an account?")
                        .foregroundStyle(.secondary)
                    Button("Sign up") {
                        path.append(.signUp)
                    }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, HackysackSpacing.large)
            .padding(.top, HackysackSpacing.large)
        }
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSubmitting)
    }

    private func submit() {
        guard isFormValid, !isSubmitting, !isRateLimited else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                try await authManager.signIn(email: email, password: password)
            } catch let error as APIError {
                if case .rateLimited(let retryAfterSeconds) = error {
                    retryAvailableAt = Date().addingTimeInterval(TimeInterval(retryAfterSeconds))
                }
                errorMessage = Self.message(for: error)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    /// The server answers an unknown email, an Apple-only account and a wrong
    /// password with the same 401, and a malformed email with a 400. All of
    /// them read as one generic message so this screen never reveals whether
    /// an account exists. APIError's own wording for a 401 ("Your session
    /// expired") is written for authenticated requests and is wrong here.
    private static func message(for error: APIError) -> String? {
        switch error {
        case .unauthorized, .server(statusCode: 400, _, _):
            return "Incorrect email or password."
        default:
            return error.errorDescription
        }
    }
}

#Preview {
    NavigationStack {
        SignInView(path: .constant([]))
            .environment(AuthManager())
    }
}
