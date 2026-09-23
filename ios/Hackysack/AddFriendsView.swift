//
//  AddFriendsView.swift
//  Hackysack
//

import SwiftUI

/// Finds people by name and sends friend requests. Presented as a sheet from
/// the Friends tab.
struct AddFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FriendsStore.self) private var friendsStore

    @State private var searchText = ""
    @State private var results: [UserSearchResult] = []
    /// The query `results` answer, so "No Results" is only shown for a search
    /// that actually finished, not one still waiting out the debounce.
    @State private var searchedQuery: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var busyUserIds: Set<String> = []
    @State private var selectedUser: UserSummary?
    /// Starts out true so the keyboard comes up with the sheet.
    @State private var isSearchFieldFocused = true

    private let friendsAPI = FriendsAPI()

    /// Capped at the API's 60-character limit, which is also the longest a
    /// name can be, so an overlong search finds nothing rather than erroring.
    private var trimmedQuery: String {
        String(searchText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    var body: some View {
        NavigationStack {
            // The ZStack gives the header one identity. Attached straight to
            // `content`, it would be rebuilt with each branch, recreating the
            // search field every time the results change.
            ZStack {
                content
            }
            // A custom header rather than `.searchable`, which only
            // activates once the sheet has finished sliding up, so the
            // field and keyboard would visibly arrive in a second step.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                header
            }
            .onChange(of: searchText) {
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await search()
                }
            }
            .navigationDestination(item: $selectedUser) { user in
                UserProfileView(user: user)
            }
            // Refreshes the row after acting on someone from their
            // profile, e.g. adding them there, and brings the keyboard
            // back so typing can carry on.
            .onChange(of: selectedUser) { _, newUser in
                if newUser == nil {
                    isSearchFieldFocused = true
                    Task { await search() }
                }
            }
        }
    }

    // MARK: Content

    private var header: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    AutofocusSearchField(
                        text: $searchText,
                        isFocused: $isSearchFieldFocused,
                        prompt: "Search by name"
                    )
                    // Full height so the clear button can have a 44pt tap
                    // target, which also stands in for trailing padding.
                    .frame(maxHeight: .infinity)
                }
                .padding(.leading, 16)
                .padding(.trailing, 2)
                .frame(height: 48)
                .contentShape(Capsule())
                .onTapGesture {
                    isSearchFieldFocused = true
                }
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView(
                "Find Friends",
                systemImage: "person.crop.circle.badge.plus",
                description: Text("Search for people by name.")
            )
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await search() }
                }
            }
        } else if !results.isEmpty {
            List(results) { result in
                row(for: result)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            // Searching is the only thing to do here, so the keyboard stays
            // up while scrolling results.
            .scrollDismissesKeyboard(.never)
        } else if searchedQuery == trimmedQuery {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(for result: UserSearchResult) -> some View {
        HStack(spacing: 12) {
            Button {
                // Put the keyboard away before the profile is pushed over it.
                isSearchFieldFocused = false
                selectedUser = result.user.summary
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: result.user.avatarURL, initials: result.user.initials)
                    Text(result.user.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows their profile")

            actionButton(for: result)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionButton(for result: UserSearchResult) -> some View {
        let isBusy = busyUserIds.contains(result.id)
        switch result.friendship.status {
        case .notFriends:
            Button("Add") {
                act(on: result) { try await friendsStore.sendRequest(to: result.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy)
        case .outgoingRequest:
            Button("Requested") {
                act(on: result) {
                    if let requestId = result.friendship.friendRequestId {
                        try await friendsStore.deleteRequest(requestId: requestId)
                    }
                    return .notFriends
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityHint("Cancels your friend request")
        case .incomingRequest:
            Button("Accept") {
                act(on: result) {
                    if let requestId = result.friendship.friendRequestId {
                        try await friendsStore.accept(requestId: requestId)
                    }
                    return .friends
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy)
        case .friends:
            Label("Friends", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    /// Runs a friendship action for one row, then shows the state it left
    /// things in. The row's button is disabled meanwhile so a double tap can't
    /// send two requests.
    private func act(
        on result: UserSearchResult,
        _ action: @escaping () async throws -> FriendshipState
    ) {
        busyUserIds.insert(result.id)
        Task {
            do {
                let friendship = try await action()
                updateFriendship(of: result.id, to: friendship)
            } catch {
                // Most likely stale: they accepted, cancelled or already
                // added you since this list loaded. Re-searching shows the
                // truth instead of an error the user can't act on.
                await search()
            }
            busyUserIds.remove(result.id)
        }
    }

    private func updateFriendship(of userId: String, to friendship: FriendshipState) {
        guard let index = results.firstIndex(where: { $0.id == userId }) else { return }
        results[index].friendship = friendship
    }

    private func search() async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            results = []
            searchedQuery = nil
            errorMessage = nil
            return
        }
        do {
            let found = try await friendsAPI.searchUsers(query: query)
            // A slower, older search must not overwrite a newer one.
            guard query == trimmedQuery else { return }
            results = found
            searchedQuery = query
            errorMessage = nil
        } catch {
            guard query == trimmedQuery else { return }
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AddFriendsView()
        .environment(FriendsStore())
        .environment(AuthManager())
}
