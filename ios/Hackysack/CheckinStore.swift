//
//  CheckinStore.swift
//  Hackysack
//

import Combine
import Foundation

enum CheckinSyncStatus: Equatable {
    /// A suggestion from a detected visit, waiting for the user to confirm, edit or remove it.
    case suggested
    case saving
    case saved
    case failed
}

/// A row in the current user's timeline. Entries created locally keep their
/// draft and photos so a failed save can be retried; entries loaded from the
/// server have neither. Suggested entries carry the pending suggestion they
/// were built from.
struct TimelineEntry: Identifiable, Equatable {
    let id: UUID
    /// Photos that finish uploading are recorded on the draft, so a retry
    /// only uploads the ones still missing.
    var draft: CheckinDraft?
    var checkin: Checkin
    var syncStatus: CheckinSyncStatus
    var suggestion: PendingCheckin? = nil
    var pendingPhotos: [PreparedPhoto] = []
}

extension TimelineEntry {
    /// A checkin that is already on the server, such as one of a friend's.
    /// The id comes from the checkin's own, so reloading keeps row identity.
    init(savedCheckin checkin: Checkin) {
        self.init(
            id: UUID(uuidString: checkin.id) ?? UUID(),
            draft: nil,
            checkin: checkin,
            syncStatus: .saved
        )
    }
}

@MainActor
final class CheckinStore: ObservableObject {
    /// Rows that exist (or are being created) on the server.
    @Published private(set) var savedEntries: [TimelineEntry] = []
    /// Device-only suggestions from detected visits, newest first.
    @Published private(set) var suggestions: [PendingCheckin] = []
    @Published private(set) var hasLoadedTimeline = false
    @Published private(set) var timelineError: String?
    /// Continues the timeline after the loaded entries; nil once it is all loaded.
    @Published private(set) var timelineNextCursor: Date?
    @Published private(set) var isLoadingMoreTimeline = false

    /// Everything the timeline shows. Suggestions are placed by their visit's
    /// arrival time, so the timeline's day grouping interleaves them naturally.
    /// A suggestion is hidden while a real checkin covers its stay; it is kept
    /// rather than withdrawn, so it comes back if that checkin goes away.
    var timelineEntries: [TimelineEntry] {
        let checkins = savedEntries.map(\.checkin)
        let now = Date()
        return suggestions
            .filter { !$0.isCovered(by: checkins, now: now) }
            .compactMap { TimelineEntry(suggestion: $0, userId: currentUserId ?? "") } + savedEntries
    }

    typealias CheckinSaver = @MainActor (CheckinDraft) async throws -> Checkin

    let visitHistory: VisitHistoryStore

    private let checkinsAPI: CheckinsAPI
    private let saveCheckin: CheckinSaver
    private let pendingFileStore: JSONFileStore<[PendingCheckin]>?

    /// A store backed by files in Application Support.
    convenience init() {
        self.init(
            visitHistory: VisitHistoryStore(),
            pendingFileStore: JSONFileStore(fileName: "pending-checkins.json"),
            saveCheckin: nil
        )
    }

    init(
        visitHistory: VisitHistoryStore,
        pendingFileStore: JSONFileStore<[PendingCheckin]>?,
        saveCheckin: CheckinSaver?
    ) {
        self.visitHistory = visitHistory
        self.pendingFileStore = pendingFileStore
        let checkinsAPI = CheckinsAPI()
        self.checkinsAPI = checkinsAPI
        if let saveCheckin {
            self.saveCheckin = saveCheckin
        } else {
            self.saveCheckin = { draft in try await checkinsAPI.createCheckin(draft) }
        }
        suggestions = pendingFileStore?.load() ?? []
    }

    /// A store that never touches disk, for previews and tests. Saves go to
    /// `saveCheckin` when given, otherwise they fail as if the network were down.
    static func inMemory(
        visitHistory: VisitHistoryStore? = nil,
        saveCheckin: CheckinSaver? = nil
    ) -> CheckinStore {
        let offline: CheckinSaver = { _ in throw APIError.transport(URLError(.notConnectedToInternet)) }
        return CheckinStore(
            visitHistory: visitHistory ?? .inMemory(),
            pendingFileStore: nil,
            saveCheckin: saveCheckin ?? offline
        )
    }

    /// The signed-in user, set by ContentView from AuthManager. Held here
    /// rather than passed into every call so TimelineView keeps calling these
    /// with no arguments.
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
            let firstPage = try await checkinsAPI.listCheckins(userId: currentUserId)
            mergeTimeline(with: firstPage)
            timelineError = nil
        } catch {
            timelineError = error.localizedDescription
        }
        hasLoadedTimeline = true
    }

    /// Drops every loaded and in-flight checkin, for a switch to another API
    /// server whose timeline must not be merged with this one's. Suggestions
    /// stay: they come from this device's visits, not from any server.
    func resetTimeline() {
        savedEntries = []
        hasLoadedTimeline = false
        timelineError = nil
        timelineNextCursor = nil
    }

    /// Loads the next page of older checkins. A failure is left for the next
    /// scroll to retry rather than shown, since the loaded ones are still fine.
    func loadMoreTimeline() async {
        guard let currentUserId, let cursor = timelineNextCursor, !isLoadingMoreTimeline else { return }
        isLoadingMoreTimeline = true
        defer { isLoadingMoreTimeline = false }
        do {
            let page = try await checkinsAPI.listCheckins(userId: currentUserId, before: cursor)
            savedEntries = CheckinPaging.appendPage(
                page.map { TimelineEntry(savedCheckin: $0) },
                to: savedEntries,
                checkin: \.checkin
            )
            timelineNextCursor = CheckinPaging.nextCursor(after: page, checkin: { $0 })
        } catch {
            DevLog.network("Couldn't load more of the timeline: \(error)")
        }
    }

    /// Optimistically inserts the checkin at the top of the timeline and saves
    /// it in the background, uploading its photos first.
    func submit(
        place: Place,
        message: String?,
        visibility: CheckinVisibility = .friends,
        photos: [PreparedPhoto] = []
    ) {
        submit(draft: CheckinDraft(place: place, message: message, visibility: visibility), photos: photos)
    }

    func retry(entryId: UUID) {
        updateEntry(entryId) { $0.syncStatus = .saving }
        Task { await save(entryId: entryId) }
    }

    private func submit(draft: CheckinDraft, photos: [PreparedPhoto] = []) {
        let entry = TimelineEntry(
            id: UUID(),
            draft: draft,
            // The placeholder needs an owner even though the draft no longer
            // carries one — the server assigns the real one from the token.
            checkin: Checkin(placeholderFor: draft, photos: photos, userId: currentUserId ?? ""),
            syncStatus: .saving,
            pendingPhotos: photos
        )
        savedEntries.insert(entry, at: 0)
        Task { await save(entryId: entry.id) }
    }

    private func save(entryId: UUID) async {
        guard let entry = savedEntries.first(where: { $0.id == entryId }), var draft = entry.draft else {
            return
        }
        do {
            // In order, so the photos keep the order they were picked in.
            for photo in entry.pendingPhotos.dropFirst(draft.photos.count) {
                draft.photos.append(try await checkinsAPI.uploadPhoto(photo))
                let uploadedPhotos = draft.photos
                updateEntry(entryId) { $0.draft?.photos = uploadedPhotos }
            }
            let savedCheckin = try await saveCheckin(draft)
            updateEntry(entryId) {
                $0.checkin = savedCheckin
                $0.syncStatus = .saved
                $0.pendingPhotos = []
            }
            // The saved checkin shows the uploaded copies now.
            for photo in entry.pendingPhotos {
                try? FileManager.default.removeItem(at: photo.localURL)
            }
            recordConfirmedCheckin(savedCheckin)
        } catch {
            updateEntry(entryId) { $0.syncStatus = .failed }
        }
    }

    /// Folds a reloaded first page into the timeline, keeping in-flight and
    /// failed local entries at the top and any older pages already loaded.
    /// Existing row identities are preserved so the list doesn't re-animate
    /// every row on refresh.
    private func mergeTimeline(with firstPage: [Checkin]) {
        let merged = CheckinPaging.mergeFirstPage(
            firstPage,
            into: savedEntries.filter { $0.syncStatus == .saved }.map(\.checkin),
            loadedCursor: timelineNextCursor,
            checkin: { $0 }
        )
        let serverIds = Set(merged.items.map(\.id))
        let pendingEntries = savedEntries.filter { entry in
            entry.syncStatus != .saved && !serverIds.contains(entry.checkin.id)
        }
        let existingEntryIds = Dictionary(
            savedEntries.map { ($0.checkin.id, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        savedEntries = pendingEntries + merged.items.map { checkin in
            TimelineEntry(
                id: existingEntryIds[checkin.id] ?? UUID(),
                draft: nil,
                checkin: checkin,
                syncStatus: .saved
            )
        }
        timelineNextCursor = merged.nextCursor
    }

    /// A like, comment or edit changed the checkin; the timeline's copy
    /// follows. Placeholders and suggestions have local ids and never match.
    func apply(_ checkin: Checkin) {
        guard let index = savedEntries.firstIndex(where: { $0.checkin.id == checkin.id }) else { return }
        savedEntries[index].checkin = checkin
    }

    private func updateEntry(_ entryId: UUID, _ mutate: (inout TimelineEntry) -> Void) {
        guard let index = savedEntries.firstIndex(where: { $0.id == entryId }) else { return }
        mutate(&savedEntries[index])
    }

    /// Lets the home/work detector know the user deliberately checks in here,
    /// so it keeps suggesting the place even if they spend all day at it.
    private func recordConfirmedCheckin(_ checkin: Checkin) {
        guard let location = checkin.location else { return }
        visitHistory.recordCheckin(
            VisitedPlaceEvent(
                coordinate: GeoCoordinate(latitude: location.latitude, longitude: location.longitude),
                placeId: checkin.placeId,
                date: checkin.createdAt
            )
        )
    }

    // MARK: Suggestions

    func suggestion(id: UUID) -> PendingCheckin? {
        suggestions.first { $0.id == id }
    }

    /// The suggestion built from this visit, if any. Also matches visits that
    /// were folded into the suggestion as a continuation of the same stay.
    func suggestion(forVisitId visitId: UUID) -> PendingCheckin? {
        suggestions.first { $0.visit.id == visitId || $0.continuationVisitIds.contains(visitId) }
    }

    func add(suggestion: PendingCheckin) {
        suggestions.removeAll { $0.id == suggestion.id }
        suggestions.insert(suggestion, at: 0)
        persistSuggestions()
    }

    /// Applies a later delivery for a suggestion's visit (normally the departure).
    func updateSuggestionVisit(_ visit: VisitRecord) {
        guard let index = suggestions.firstIndex(where: {
            $0.visit.id == visit.id || $0.continuationVisitIds.contains(visit.id)
        }) else { return }
        if suggestions[index].visit.id == visit.id {
            suggestions[index].visit = visit
        } else {
            suggestions[index].visit.departureDate = visit.departureDate
        }
        persistSuggestions()
    }

    /// Folds a re-arrival into an existing suggestion: the stay is ongoing again
    /// and later deliveries for the new visit update this suggestion.
    func extendSuggestion(id: UUID, with visit: VisitRecord) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].continuationVisitIds.append(visit.id)
        suggestions[index].visit.departureDate = visit.departureDate
        persistSuggestions()
    }

    /// Drops a suggestion without treating it as a rejection (the visit turned
    /// out to be too short to have been a real stay).
    func withdrawSuggestion(id: UUID) {
        suggestions.removeAll { $0.id == id }
        persistSuggestions()
    }

    /// Turns the suggestion into a real checkin at its selected place.
    func accept(suggestionId: UUID) {
        guard let suggestion = suggestion(id: suggestionId), let place = suggestion.selectedPlace else { return }
        suggestions.removeAll { $0.id == suggestionId }
        persistSuggestions()
        submit(
            draft: CheckinDraft(
                place: place,
                message: nil,
                visibility: suggestion.visibility,
                source: .visit,
                createdAt: suggestion.visit.arrivalDate
            )
        )
    }

    /// Accepts the suggestion with the place and visibility chosen in the
    /// edit sheet, which may differ from the initial guess.
    func confirm(suggestionId: UUID, place: Place, visibility: CheckinVisibility) {
        guard let index = suggestions.firstIndex(where: { $0.id == suggestionId }) else { return }
        if !suggestions[index].candidatePlaces.contains(where: { $0.id == place.id }) {
            suggestions[index].candidatePlaces.insert(place, at: 0)
        }
        suggestions[index].selectedPlaceId = place.id
        suggestions[index].visibility = visibility
        accept(suggestionId: suggestionId)
    }

    /// The user says this stay is not a checkin. Remembered so the detector
    /// stops suggesting the spot.
    func remove(suggestionId: UUID, now: Date = Date()) {
        guard let suggestion = suggestion(id: suggestionId) else { return }
        suggestions.removeAll { $0.id == suggestionId }
        persistSuggestions()
        visitHistory.recordRejection(RemovedSuggestion(coordinate: suggestion.visit.coordinate, date: now))
    }

    private func persistSuggestions() {
        pendingFileStore?.save(suggestions)
    }
}

private extension Checkin {
    /// A local stand-in shown in the timeline until the server responds. Its
    /// photos point at the local copies, which load like any other URL.
    init(placeholderFor draft: CheckinDraft, photos: [PreparedPhoto], userId: String) {
        let now = Date()
        let place = draft.place
        self.init(
            id: "local-\(UUID().uuidString)",
            userId: userId,
            placeId: place.id,
            placeName: place.name,
            placeAddress: place.address,
            placeLocality: place.locality,
            placePrimaryType: place.primaryType,
            placeTypes: place.types.isEmpty ? nil : place.types,
            placeCategoryName: place.categoryName,
            location: place.location,
            message: draft.message,
            visibility: draft.visibility,
            source: draft.source,
            photos: photos.map { photo in
                CheckinPhoto(id: photo.id.uuidString, url: photo.localURL, width: photo.width, height: photo.height)
            },
            timeZoneOffsetMinutes: draft.timeZoneOffsetMinutes,
            createdAt: draft.createdAt ?? now,
            updatedAt: now
        )
    }
}

extension TimelineEntry {
    /// A timeline row for a suggestion: a placeholder checkin at the selected
    /// place, dated to the visit's arrival. `nil` when the suggestion has no
    /// usable place (which the processor never produces, but the file could).
    init?(suggestion: PendingCheckin, userId: String) {
        guard let place = suggestion.selectedPlace else { return nil }
        self.init(
            id: suggestion.id,
            draft: nil,
            checkin: Checkin(
                id: "suggestion-\(suggestion.id.uuidString)",
                userId: userId,
                placeId: place.id,
                placeName: place.name,
                placeAddress: place.address,
                placeLocality: place.locality,
                placePrimaryType: place.primaryType,
                placeTypes: place.types,
                placeCategoryName: place.categoryName,
                location: place.location,
                message: nil,
                visibility: suggestion.visibility,
                source: .visit,
                timeZoneOffsetMinutes: TimeZone.current.secondsFromGMT(for: suggestion.visit.arrivalDate) / 60,
                createdAt: suggestion.visit.arrivalDate,
                updatedAt: suggestion.createdAt
            ),
            syncStatus: .suggested,
            suggestion: suggestion
        )
    }
}

#if DEBUG
extension CheckinStore {
    /// For DebugVisitMenu: start the suggestion flow over.
    func removeAllSuggestions() {
        suggestions.removeAll()
        persistSuggestions()
    }
}
#endif
