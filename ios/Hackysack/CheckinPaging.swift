//
//  CheckinPaging.swift
//  Hackysack
//

import Foundation

/// Shared by every checkin list that pages: the timeline, the friends feed and
/// profiles. Pages come newest first, and the next one is fetched with the
/// `createdAt` of the last row already loaded (the API's `before`). Someone
/// with years of Swarm history has thousands of checkins, so lists load 50 at
/// a time and keep scrolling.
nonisolated enum CheckinPaging {
    static let pageSize = 50

    /// The cursor for the page after `page`, or nil when the page came back
    /// short and is therefore the last.
    static func nextCursor<Item>(after page: [Item], checkin: (Item) -> Checkin) -> Date? {
        guard page.count >= pageSize, let last = page.last else { return nil }
        return checkin(last).createdAt
    }

    /// Folds a freshly loaded first page into a list that may already hold
    /// later pages.
    ///
    /// Lists reload their first page whenever they appear and on pull to
    /// refresh. Replacing the list with that page would throw away everything
    /// scrolled to beyond it and jump the scroll position, so items older than
    /// the new page are kept, along with the cursor that continues after them.
    static func mergeFirstPage<Item>(
        _ firstPage: [Item],
        into loaded: [Item],
        loadedCursor: Date?,
        checkin: (Item) -> Checkin
    ) -> (items: [Item], nextCursor: Date?) {
        // No cursor means the first page is the whole history.
        guard let pageEnd = nextCursor(after: firstPage, checkin: checkin) else {
            return (firstPage, nil)
        }
        let firstPageIds = Set(firstPage.map { checkin($0).id })
        let olderItems = loaded.filter {
            checkin($0).createdAt < pageEnd && !firstPageIds.contains(checkin($0).id)
        }
        guard !olderItems.isEmpty else {
            return (firstPage, pageEnd)
        }
        return (firstPage + olderItems, loadedCursor)
    }

    /// Appends a later page, skipping anything already in the list, which can
    /// happen when a new checkin shifts the pages between requests.
    static func appendPage<Item>(_ page: [Item], to loaded: [Item], checkin: (Item) -> Checkin) -> [Item] {
        let loadedIds = Set(loaded.map { checkin($0).id })
        return loaded + page.filter { !loadedIds.contains(checkin($0).id) }
    }
}
