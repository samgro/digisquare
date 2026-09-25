//
//  TestUsersView.swift
//  Hackysack
//

#if DEBUG
import SwiftUI

/// Debug builds only: sign in as a test user with no credential, or create a
/// new one to walk through the new user flow. Needs the API running with
/// ENABLE_TEST_USERS set; see api/SETUP.md.
struct TestUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthManager.self) private var authManager

    @State private var testUsers: [UserSummary] = []
    @State private var isLoading = true
    @State private var busyUserId: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var isBusy: Bool { busyUserId != nil || isCreating }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(testUsers) { testUser in
                        row(for: testUser)
                    }
                } footer: {
                    if !isLoading && testUsers.isEmpty {
                        Text("No test users yet. Run npm run db:seed-test-users in api.")
                    }
                }

                Section {
                    Button {
                        createTestUser()
                    } label: {
                        HStack {
                            Label("Add Test User", systemImage: Glyphs.add)
                            Spacer(minLength: 0)
                            if isCreating {
                                ProgressView()
                            }
                        }
                    }
                } footer: {
                    Text("Creates a new test user and starts the new user flow.")
                }
            }
            .listStyle(.insetGrouped)
            .disabled(isBusy)
            .overlay {
                if isLoading && testUsers.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Test Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let errorMessage {
                    FormErrorBanner(message: errorMessage)
                        .padding(.horizontal, HackysackSpacing.medium)
                }
            }
            .refreshable {
                await loadTestUsers()
            }
            .task {
                await loadTestUsers()
            }
        }
    }

    private func row(for testUser: UserSummary) -> some View {
        Button {
            signIn(as: testUser)
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: testUser.avatarURL, initials: testUser.initials)
                Text(testUser.name ?? "Unnamed test user")
                    .font(.headline)
                    .foregroundStyle(testUser.name == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if busyUserId == testUser.id {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func loadTestUsers() async {
        do {
            testUsers = try await authManager.fetchTestUsers()
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
        isLoading = false
    }

    /// Signing in swaps RootView away from WelcomeView, which takes this
    /// cover with it; the dismiss only makes sure nothing is left behind.
    private func signIn(as testUser: UserSummary) {
        busyUserId = testUser.id
        errorMessage = nil
        Task {
            do {
                try await authManager.signInAsTestUser(id: testUser.id)
                dismiss()
            } catch {
                errorMessage = message(for: error)
            }
            busyUserId = nil
        }
    }

    private func createTestUser() {
        isCreating = true
        errorMessage = nil
        Task {
            do {
                try await authManager.createTestUser()
                dismiss()
            } catch {
                errorMessage = message(for: error)
            }
            isCreating = false
        }
    }

    /// A 404 here almost always means the API is running without
    /// ENABLE_TEST_USERS, so say that rather than "Not found".
    private func message(for error: any Error) -> String {
        if case .server(statusCode: 404, message: _, fieldErrors: _)? = error as? APIError {
            return "Test users are turned off. Set ENABLE_TEST_USERS=true for the API."
        }
        return error.localizedDescription
    }
}

#Preview {
    TestUsersView()
        .environment(AuthManager())
}
#endif
