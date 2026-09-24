//
//  CheckinSocialStore.swift
//  Hackysack
//

import Foundation
import Observation

/// Likes, comments and edits, from wherever they happen. The timeline, the
/// Friends feed and an open detail page each hold their own copy of a
/// checkin, so every change is published through `onCheckinChanged` for the
/// feeds to apply and kept in `latest` for the detail page to read.
@Observable
@MainActor
final class CheckinSocialStore {
    /// The most recent version of every checkin that changed in this session.
    private(set) var latest: [String: Checkin] = [:]
    /// Checkins with a like request in flight, so a double tap sends one.
    private var likingCheckinIds: Set<String> = []

    /// Set by ContentView to fan out to the stores that hold checkins.
    @ObservationIgnored var onCheckinChanged: (Checkin) -> Void = { _ in }
    @ObservationIgnored private let checkinsAPI = CheckinsAPI()

    /// `checkin` as it stands now, if something changed it since it was loaded.
    func current(_ checkin: Checkin) -> Checkin {
        latest[checkin.id] ?? checkin
    }

    /// Optimistic: the heart flips at once, then settles on the server's
    /// count, or flips back if the request failed.
    func toggleLike(_ checkin: Checkin) async throws {
        guard !likingCheckinIds.contains(checkin.id) else { return }
        likingCheckinIds.insert(checkin.id)
        defer { likingCheckinIds.remove(checkin.id) }

        var optimistic = checkin
        optimistic.likedByMe.toggle()
        optimistic.likeCount = max(0, checkin.likeCount + (optimistic.likedByMe ? 1 : -1))
        publish(optimistic)

        do {
            let state: CheckinLikeState
            if optimistic.likedByMe {
                state = try await checkinsAPI.like(checkinId: checkin.id)
            } else {
                state = try await checkinsAPI.unlike(checkinId: checkin.id)
            }
            var settled = current(checkin)
            settled.likeCount = state.likeCount
            settled.likedByMe = state.likedByMe
            publish(settled)
        } catch {
            publish(checkin)
            throw error
        }
    }

    func edit(_ checkin: Checkin, update: CheckinUpdate) async throws -> Checkin {
        let updated = try await checkinsAPI.updateCheckin(id: checkin.id, update)
        publish(updated)
        return updated
    }

    /// Fetches the checkin afresh, for a detail page opened from a row that
    /// may have gone stale.
    func refresh(_ checkin: Checkin) async throws -> Checkin {
        let fresh = try await checkinsAPI.checkin(id: checkin.id)
        publish(fresh)
        return fresh
    }

    func didAddComment(to checkin: Checkin) {
        var changed = current(checkin)
        changed.commentCount += 1
        publish(changed)
    }

    func didDeleteComment(from checkin: Checkin) {
        var changed = current(checkin)
        changed.commentCount = max(0, changed.commentCount - 1)
        publish(changed)
    }

    private func publish(_ checkin: Checkin) {
        latest[checkin.id] = checkin
        onCheckinChanged(checkin)
    }
}
