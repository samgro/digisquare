//
//  CheckinStore.swift
//  Hackysack
//

import Combine
import Foundation

enum CheckinSyncStatus: Equatable {
    case saving
    case saved
    case failed
}

/// A row in the current user's timeline. Entries created locally keep their
/// draft so a failed save can be retried; entries loaded from the server have none.
struct TimelineEntry: Identifiable, Equatable {
    let id: UUID
    let draft: CheckinDraft?
    var checkin: Checkin
    var syncStatus: CheckinSyncStatus
}

@MainActor
final class CheckinStore: ObservableObject {
    @Published private(set) var timelineEntries: [TimelineEntry] = []
    @Published private(set) var friendsCheckins: [Checkin] = []
    @Published private(set) var hasLoadedTimeline = false
    @Published private(set) var hasLoadedFriends = false
    @Published private(set) var timelineError: String?
    @Published private(set) var friendsError: String?

    private let checkinsAPI = CheckinsAPI()

    /// The signed-in user, set by ContentView from AuthManager. Held here
    /// rather than passed into every call so TimelineView and FriendsView keep
    /// calling these with no arguments.
    ///
    /// Nil only before the first assignment; ContentView is behind the auth
    /// gate, so by the time it appears there is always a signed-in user.
    var currentUserId: String?

    // MARK: Timeline

    func loadTimeline() async {
        guard let currentUserId else {
            // Nothing to scope the timeline to yet. Leaving hasLoadedTimeline
            // false means the view keeps its loading state and tries again,
            // rather than rendering a permanent empty timeline.
            return
        }
        do {
            let serverCheckins = try await checkinsAPI.listCheckins(userId: currentUserId)
            mergeTimeline(with: serverCheckins)
            timelineError = nil
        } catch {
            timelineError = error.localizedDescription
        }
        hasLoadedTimeline = true
    }

    /// Optimistically inserts the checkin at the top of the timeline and saves it in the background.
    func submit(place: Place, message: String?) {
        let draft = CheckinDraft(place: place, message: message)
        let entry = TimelineEntry(
            id: UUID(),
            draft: draft,
            // The placeholder needs an owner even though the draft no longer
            // carries one — the server assigns the real one from the token.
            checkin: Checkin(placeholderFor: draft, userId: currentUserId ?? ""),
            syncStatus: .saving
        )
        timelineEntries.insert(entry, at: 0)
        Task { await save(entryId: entry.id) }
    }

    func retry(entryId: UUID) {
        updateEntry(entryId) { $0.syncStatus = .saving }
        Task { await save(entryId: entryId) }
    }

    private func save(entryId: UUID) async {
        guard let entry = timelineEntries.first(where: { $0.id == entryId }), let draft = entry.draft else {
            return
        }
        do {
            let savedCheckin = try await checkinsAPI.createCheckin(draft)
            updateEntry(entryId) {
                $0.checkin = savedCheckin
                $0.syncStatus = .saved
            }
            if hasLoadedFriends, !friendsCheckins.contains(where: { $0.id == savedCheckin.id }) {
                friendsCheckins.insert(savedCheckin, at: 0)
            }
        } catch {
            updateEntry(entryId) { $0.syncStatus = .failed }
        }
    }

    /// Replaces saved rows with the server's list while keeping in-flight and failed
    /// local entries at the top. Existing row identities are preserved so the list
    /// doesn't re-animate every row on refresh.
    private func mergeTimeline(with serverCheckins: [Checkin]) {
        let serverIds = Set(serverCheckins.map(\.id))
        let pendingEntries = timelineEntries.filter { entry in
            entry.syncStatus != .saved && !serverIds.contains(entry.checkin.id)
        }
        let existingEntryIds = Dictionary(
            timelineEntries.map { ($0.checkin.id, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        timelineEntries = pendingEntries + serverCheckins.map { checkin in
            TimelineEntry(
                id: existingEntryIds[checkin.id] ?? UUID(),
                draft: nil,
                checkin: checkin,
                syncStatus: .saved
            )
        }
    }

    private func updateEntry(_ entryId: UUID, _ mutate: (inout TimelineEntry) -> Void) {
        guard let index = timelineEntries.firstIndex(where: { $0.id == entryId }) else { return }
        mutate(&timelineEntries[index])
    }

    // MARK: Friends

    func loadFriends() async {
        do {
            friendsCheckins = try await checkinsAPI.listCheckins()
            friendsError = nil
        } catch {
            friendsError = error.localizedDescription
        }
        hasLoadedFriends = true
    }
}

private extension Checkin {
    /// A local stand-in shown in the timeline until the server responds.
    init(placeholderFor draft: CheckinDraft, userId: String) {
        let now = Date()
        var location: PlaceLocation?
        if let latitude = draft.latitude, let longitude = draft.longitude {
            location = PlaceLocation(latitude: latitude, longitude: longitude)
        }
        self.init(
            id: "local-\(UUID().uuidString)",
            userId: userId,
            googlePlaceId: draft.googlePlaceId,
            placeName: draft.placeName,
            placeAddress: draft.placeAddress,
            placePrimaryType: draft.placePrimaryType,
            placeTypes: draft.placeTypes,
            location: location,
            message: draft.message,
            createdAt: now,
            updatedAt: now
        )
    }
}
