//
//  WelcomeView.swift
//  Hackysack
//

import AuthenticationServices
import SwiftUI

struct WelcomeView: View {
    @Environment(AuthManager.self) private var authManager

    @State private var currentNonce: String?
    @State private var isAuthenticating = false
    @State private var errorMessage: String?
    #if DEBUG
    @State private var isShowingTestUsers = false
    #endif

    var body: some View {
        VStack(spacing: HackysackSpacing.large) {
            Spacer()

            VStack(spacing: HackysackSpacing.medium) {
                Image(systemName: Glyphs.appLogo)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(AppInfo.name)
                    .font(.largeTitle.bold())
                Text("Check in. Share where you've been.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let errorMessage {
                FormErrorBanner(message: errorMessage)
            }

            VStack(spacing: HackysackSpacing.medium) {
                SignInWithAppleButton(.signIn) { request in
                    let nonce = AppleSignInSupport.randomNonce()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleSignInSupport.sha256Hexadecimal(nonce)
                } onCompletion: { result in
                    handleAppleCompletion(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: HackysackSize.controlHeight)
                .clipShape(
                    RoundedRectangle(cornerRadius: HackysackRadius.control, style: .continuous)
                )
                .disabled(isAuthenticating)

                #if DEBUG
                Button("Log In as Test User") {
                    isShowingTestUsers = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isAuthenticating)
                #endif
            }

            if isAuthenticating {
                ProgressView()
            }
        }
        .padding(.horizontal, HackysackSpacing.large)
        .padding(.bottom, HackysackSpacing.extraLarge)
        #if DEBUG
        .fullScreenCover(isPresented: $isShowingTestUsers) {
            TestUsersView()
        }
        #endif
    }

    private func handleAppleCompletion(
        _ result: Result<ASAuthorization, any Error>
    ) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = credential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Couldn't read your Apple credentials. Please try again."
                return
            }

            errorMessage = nil
            isAuthenticating = true
            Task {
                do {
                    // fullName and email arrive ONLY on the first
                    // authorization for this Apple ID. To test this path
                    // again, revoke the app under Settings > Apple ID > Sign
                    // in with Apple.
                    let emailConflict = try await authManager.signInWithApple(
                        identityToken: identityToken,
                        nonce: nonce,
                        fullName: credential.fullName,
                        email: credential.email
                    )
                    if emailConflict {
                        errorMessage = """
                            We created a new account for you. An account with this \
                            email address already exists.
                            """
                    }
                } catch {
                    errorMessage = (error as? APIError)?.errorDescription
                        ?? "Couldn't sign in with Apple."
                }
                isAuthenticating = false
            }

        case .failure(let error):
            // Cancelling is not an error worth showing anyone.
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }
            errorMessage = "Couldn't sign in with Apple."
        }
    }
}

#Preview {
    WelcomeView()
        .environment(AuthManager())
}
