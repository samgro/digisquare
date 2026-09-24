//
//  PreviewData.swift
//  Hackysack
//

import Foundation

extension Place {
    static let preview = Place(
        id: "ChIJpreview",
        name: "Blue Bottle Coffee",
        address: "315 Linden St, San Francisco",
        location: PlaceLocation(latitude: 37.7764, longitude: -122.4231),
        types: ["cafe", "coffee_shop"],
        primaryType: "cafe",
        rating: 4.5,
        userRatingCount: 1200
    )
}

extension Checkin {
    static func preview(
        id: String = UUID().uuidString,
        userId: String = "00000000-0000-0000-0000-00000000da7a",
        message: String? = "Best cortado in the Mission",
        primaryType: String? = "cafe",
        minutesAgo: Double = 2,
        visibility: CheckinVisibility = .friends,
        source: CheckinSource = .manual,
        likeCount: Int = 0,
        commentCount: Int = 0,
        likedByMe: Bool = false
    ) -> Checkin {
        let createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        return Checkin(
            id: id,
            userId: userId,
            googlePlaceId: Place.preview.id,
            placeName: Place.preview.name,
            placeAddress: Place.preview.address,
            placePrimaryType: primaryType,
            placeTypes: Place.preview.types,
            location: Place.preview.location,
            message: message,
            visibility: visibility,
            source: source,
            likeCount: likeCount,
            commentCount: commentCount,
            likedByMe: likedByMe,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

extension PublicUser {
    static func preview(
        id: String = "00000000-0000-0000-0000-0000000a1e70",
        name: String? = "Alex Rivera",
        bio: String? = "Chasing the perfect cortado."
    ) -> PublicUser {
        PublicUser(
            id: id,
            name: name,
            bio: bio,
            avatarURL: nil,
            hometown: "Oakland, CA",
            createdAt: Date().addingTimeInterval(-86_400 * 200)
        )
    }
}

extension FriendCheckin {
    static func preview(user: PublicUser = .preview()) -> FriendCheckin {
        FriendCheckin(checkin: .preview(userId: user.id), user: user.summary)
    }
}

extension CheckinComment {
    static func preview(
        user: PublicUser = .preview(),
        body: String = "Best seat in the house.",
        minutesAgo: Double = 12
    ) -> CheckinComment {
        CheckinComment(
            id: UUID().uuidString,
            checkinId: "checkin-preview",
            body: body,
            createdAt: Date().addingTimeInterval(-minutesAgo * 60),
            user: user.summary
        )
    }
}

extension AppNotification {
    static func preview(
        kind: NotificationKind,
        actor: PublicUser = .preview(),
        isUnread: Bool = true,
        minutesAgo: Double = 30
    ) -> AppNotification {
        let isAboutCheckin = kind == .like || kind == .comment
        return AppNotification(
            id: UUID().uuidString,
            kind: kind,
            actor: actor.summary,
            checkin: isAboutCheckin ? CheckinReference(id: "checkin-preview", placeName: Place.preview.name) : nil,
            comment: kind == .comment ? CommentReference(id: "comment-preview", body: "Best seat in the house.") : nil,
            friendship: isAboutCheckin ? nil : FriendshipReference(
                id: "friendship-preview",
                status: kind == .friendRequest ? .pending : .accepted
            ),
            readAt: isUnread ? nil : Date().addingTimeInterval(-60),
            createdAt: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }
}
