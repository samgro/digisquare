//
//  CheckinRecord.swift
//  Hackysack
//

import Foundation
import SwiftData

/// The local copy of one of the signed-in user's checkins. The timeline and
/// search both read from these, and CheckinHistorySync keeps them in step
/// with the server.
///
/// Flattened rather than nesting `Checkin`, so every field is a plain column
/// SwiftData can store and sort on.
@Model
final class CheckinRecord {
    @Attribute(.unique) var id: String = ""
    var userId: String = ""
    var placeId: String = ""
    var placeName: String = ""
    var placeAddress: String?
    var placeLocality: String?
    /// ISO 3166-2, e.g. "US-CA".
    var placeRegion: String?
    /// ISO 3166-1 alpha-2, e.g. "US".
    var placeCountry: String?
    var placePrimaryType: String?
    var placeTypes: [String]?
    /// The source's own category label, such as Foursquare's "Hotpot Restaurant".
    var placeCategoryName: String?
    var latitude: Double?
    var longitude: Double?
    var message: String?
    /// `CheckinVisibility`'s raw value.
    var visibility: String = CheckinVisibility.friends.rawValue
    /// `CheckinSource`'s raw value.
    var source: String = CheckinSource.manual.rawValue
    var photos: [CheckinPhoto] = []
    /// Minutes east of UTC where the checkin happened.
    var timeZoneOffsetMinutes: Int?
    /// As of the last sync, or the last change made on this device.
    var likeCount: Int = 0
    var commentCount: Int = 0
    var likedByMe: Bool = false
    var createdAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    /// Everything free-text search matches against, folded once here so
    /// searching thousands of checkins per keystroke is a plain `contains`.
    var searchableText: String = ""

    init(checkin: Checkin) {
        id = checkin.id
        update(from: checkin)
    }

    func update(from checkin: Checkin) {
        userId = checkin.userId
        placeId = checkin.placeId
        placeName = checkin.placeName
        placeAddress = checkin.placeAddress
        placeLocality = checkin.locality
        placeRegion = checkin.placeRegion
        placeCountry = checkin.placeCountry
        placePrimaryType = checkin.placePrimaryType
        placeTypes = checkin.placeTypes
        placeCategoryName = checkin.placeCategoryName
        latitude = checkin.location?.latitude
        longitude = checkin.location?.longitude
        message = checkin.message
        visibility = checkin.visibility.rawValue
        source = checkin.source.rawValue
        photos = checkin.photos
        timeZoneOffsetMinutes = checkin.timeZoneOffsetMinutes
        likeCount = checkin.likeCount
        commentCount = checkin.commentCount
        likedByMe = checkin.likedByMe
        createdAt = checkin.createdAt
        updatedAt = checkin.updatedAt

        // Both labels when a Swarm import kept Foursquare's: "hotpot" and
        // "asian restaurant" each find it.
        let categoryName = placePrimaryType.map { PlaceTypeSymbol.displayName(for: $0) }
        let searchableParts: [String?] = [
            placeName,
            message,
            placeAddress,
            placeCategoryName,
            categoryName,
            placeLocality,
            placeRegion.map(RegionName.administrativeArea),
            placeCountry.map(RegionName.country),
        ]
        searchableText = CheckinSearch.normalized(
            searchableParts.compactMap { $0 }.joined(separator: "\n")
        )
    }

    /// The API shape, so the shared rows render a record exactly like a
    /// checkin fresh from the server.
    var checkin: Checkin {
        var location: PlaceLocation?
        if let latitude, let longitude {
            location = PlaceLocation(latitude: latitude, longitude: longitude)
        }
        return Checkin(
            id: id,
            userId: userId,
            placeId: placeId,
            placeName: placeName,
            placeAddress: placeAddress,
            placeLocality: placeLocality,
            placeRegion: placeRegion,
            placeCountry: placeCountry,
            placePrimaryType: placePrimaryType,
            placeTypes: placeTypes,
            placeCategoryName: placeCategoryName,
            location: location,
            message: message,
            visibility: CheckinVisibility(rawValue: visibility) ?? .friends,
            source: CheckinSource(rawValue: source) ?? .manual,
            photos: photos,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes,
            likeCount: likeCount,
            commentCount: commentCount,
            likedByMe: likedByMe,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// Where the sync left off, stored beside the records it describes so the two
/// are always saved together: a sync killed mid-page resumes from exactly the
/// last page it committed. One row per database.
@Model
final class CheckinSyncState {
    /// Opaque; sent back to `GET /checkins/sync` verbatim.
    var cursor: String?
    var totalCount: Int?
    var hasCompletedInitialSync: Bool = false
    var lastSuccessfulSyncAt: Date?

    init() {}
}
