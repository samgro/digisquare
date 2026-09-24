//
//  NotificationsStore.swift
//  Hackysack
//

import Foundation
import Observation

/// The bell: its badge count, kept current whenever the app comes forward,
/// and the feed behind it.
@Observable
@MainActor
final class NotificationsStore {
    private(set) var items: [AppNotification] = []
    private(set) var unreadCount = 0
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var isLoadingMore = false
    /// False once a page came back short, so the list stops asking.
    private(set) var hasMore = true

    @ObservationIgnored private let notificationsAPI = NotificationsAPI()
    private static let pageSize = 30

    func load() async {
        do {
            let page = try await notificationsAPI.list(limit: Self.pageSize)
            items = page.results
            unreadCount = page.unreadCount
            hasMore = page.results.count == Self.pageSize
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// The page after the last row shown. Quiet on failure: the rows already
    /// on screen are still right, and a pull to refresh starts over.
    func loadMore() async {
        guard hasMore, !isLoadingMore, let last = items.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await notificationsAPI.list(limit: Self.pageSize, before: last.createdAt)
            items += page.results
            unreadCount = page.unreadCount
            hasMore = page.results.count == Self.pageSize
        } catch {
            DevLog.network("Couldn't load more notifications: \(error)")
        }
    }

    /// Drives the badge, so a failure keeps whatever was last known rather
    /// than clearing a badge the user may be about to act on.
    func refreshUnreadCount() async {
        do {
            unreadCount = try await notificationsAPI.unreadCount()
        } catch {
            DevLog.network("Couldn't refresh the notification count: \(error)")
        }
    }

    /// Clears the badge. The rows keep their unread marks until the next
    /// load, so what was new is still visible while the feed is open.
    func markAllRead() async {
        guard unreadCount > 0 else { return }
        do {
            try await notificationsAPI.markAllRead()
            unreadCount = 0
        } catch {
            DevLog.network("Couldn't mark notifications read: \(error)")
        }
    }

    /// Drops a friend request that was just answered; the server has already
    /// retired it.
    func remove(id: String) {
        items.removeAll { $0.id == id }
    }
}
