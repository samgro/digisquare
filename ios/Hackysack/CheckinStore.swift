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

/// A row in the current user's timeline that isn't in the local database:
/// a checkin being saved, one whose save failed, or a suggestion. Entries
/// created locally keep their draft and photos so a failed save can be
/// retried. Suggested entries carry the pending suggestion they were built
/// from. Profiles also wrap the checkins they load in these.
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
    /// Checkins still being saved, or whose save failed. Saved checkins move
    /// to the local database, which is what the timeline shows beside these;
    /// one the database couldn't take stays here, marked saved, until a sync
    /// brings it down.
    @Published private(set) var pendingEntries: [TimelineEntry] = []
    /// Device-only suggestions from detected visits, newest first.
    @Published private(set) var suggestions: [PendingCheckin] = []
    /// The most recent checkin this device finished saving, for screens that
    /// reload when the user's checkins change.
    @Published private(set) var lastSavedCheckinId: String?

    /// Everything the timeline shows apart from the local database: pending
    /// checkins and suggestions. Suggestions are placed by their visit's
    /// arrival time, so the timeline's day grouping interleaves them
    /// naturally. A suggestion is hidden while a real checkin covers its
    /// stay; it is kept rather than withdrawn, so it comes back if that
    /// checkin goes away.
    var timelineEntries: [TimelineEntry] {
        let pendingCheckins = pendingEntries.map(\.checkin)
        let now = Date()
        return suggestions
            .filter { suggestion in
                let storedCheckins = historySync?.checkins(createdIn: suggestion.coverageWindow(now: now)) ?? []
                return !suggestion.isCovered(by: pendingCheckins + storedCheckins, now: now)
            }
            .compactMap { TimelineEntry(suggestion: $0, userId: currentUserId ?? "") } + pendingEntries
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

    /// The signed-in user's local history, where saved checkins go. Set by
    /// ContentView once the database is open; nil when Core Location
    /// launched the app for a visit with no UI.
    weak var historySync: CheckinHistorySync?

    // MARK: Timeline

    /// Brings the timeline up to date: a sync pass for anything new or
    /// edited, plus a reload of the newest checkins, since a like or comment
    /// doesn't count as an edit and the sync never sees them. Older
    /// checkins' counts catch up when one is opened.
    ///
    /// Failures are quiet; the timeline explains sync trouble itself.
    func refreshTimeline() async {
        guard let currentUserId, let historySync else { return }
        async let syncPass: Void = historySync.refresh()
        do {
            let recentCheckins = try await checkinsAPI.listCheckins(userId: currentUserId)
            historySync.store(recentCheckins)
        } catch {
            DevLog.network("Couldn't refresh recent checkins: \(error)")
        }
        await syncPass
    }

    /// Drops every in-flight checkin, for a switch to another API server
    /// whose timeline must not be merged with this one's. Each server has its
    /// own local database, which ContentView opens afresh. Suggestions stay:
    /// they come from this device's visits, not from any server.
    func resetTimeline() {
        pendingEntries = []
        lastSavedCheckinId = nil
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
        pendingEntries.insert(entry, at: 0)
        Task { await save(entryId: entry.id) }
    }

    private func save(entryId: UUID) async {
        guard let entry = pendingEntries.first(where: { $0.id == entryId }), var draft = entry.draft else {
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
            // Store first, then drop the pending row, so the timeline never
            // renders a frame with neither. If the local store couldn't take
            // it, keep the row, now marked saved, until a sync brings it down.
            if historySync?.store(savedCheckin) == true {
                pendingEntries.removeAll { $0.id == entryId }
            } else {
                updateEntry(entryId) {
                    $0.checkin = savedCheckin
                    $0.syncStatus = .saved
                    $0.pendingPhotos = []
                }
                historySync?.requestSync()
            }
            // The saved checkin shows the uploaded copies now.
            for photo in entry.pendingPhotos {
                try? FileManager.default.removeItem(at: photo.localURL)
            }
            lastSavedCheckinId = savedCheckin.id
            recordConfirmedCheckin(savedCheckin)
        } catch {
            updateEntry(entryId) { $0.syncStatus = .failed }
        }
    }

    /// A like, comment or edit changed the checkin; the timeline's copy
    /// follows. Friends' checkins pass through here too and are ignored.
    func apply(_ checkin: Checkin) {
        historySync?.updateIfStored(checkin)
        guard let index = pendingEntries.firstIndex(where: { $0.checkin.id == checkin.id }) else { return }
        pendingEntries[index].checkin = checkin
    }

    private func updateEntry(_ entryId: UUID, _ mutate: (inout TimelineEntry) -> Void) {
        guard let index = pendingEntries.firstIndex(where: { $0.id == entryId }) else { return }
        mutate(&pendingEntries[index])
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
            placeRegion: place.region,
            placeCountry: place.country,
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
                placeRegion: place.region,
                placeCountry: place.country,
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
