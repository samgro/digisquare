//
//  SocialDecodingTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Social decoding")
struct SocialDecodingTests {
    private static let checkinJSON = """
    {
      "id": "0f1c5a8e-4c6c-4a3b-9c48-2f4d1a0a3d11",
      "userId": "550e8400-e29b-41d4-a716-446655440000",
      "googlePlaceId": "ChIJpreview",
      "placeName": "Blue Bottle Coffee",
      "placeAddress": "315 Linden St, San Francisco",
      "placePrimaryType": "cafe",
      "placeTypes": ["cafe", "coffee_shop"],
      "location": { "latitude": 37.7764, "longitude": -122.4231 },
      "message": null,
      "visibility": "friends",
      "source": "manual",
      "likeCount": 3,
      "commentCount": 1,
      "likedByMe": true,
      "createdAt": "2026-09-20T14:15:00.000Z",
      "updatedAt": "2026-09-21T10:00:00.000Z"
    }
    """

    @Test("Decodes the like and comment counts the API now sends")
    func decodesSocialCounts() throws {
        let checkin = try RankingFixtures.makeDecoder().decode(Checkin.self, from: Data(Self.checkinJSON.utf8))

        #expect(checkin.likeCount == 3)
        #expect(checkin.commentCount == 1)
        #expect(checkin.likedByMe)
    }

    @Test("A feed row is the checkin plus its owner, and the counts come along")
    func decodesFriendCheckin() throws {
        let json = String(Self.checkinJSON.dropLast(2))
            + """
            ,
              "user": { "id": "550e8400-e29b-41d4-a716-446655440000", "name": "Alex", "avatarUrl": null }
            }
            """
        let item = try RankingFixtures.makeDecoder().decode(FriendCheckin.self, from: Data(json.utf8))

        #expect(item.user.displayName == "Alex")
        #expect(item.checkin.likeCount == 3)
    }

    @Test("A checkin update always sends the message, as null when cleared")
    func encodesClearedMessage() throws {
        let cleared = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CheckinUpdate(message: "   ", visibility: .onlyMe))
        ) as? [String: Any]

        #expect(cleared?["message"] is NSNull)
        #expect(cleared?["visibility"] as? String == "private")
    }

    @Test("Decodes a comment with its author's summary")
    func decodesComment() throws {
        let json = """
        {
          "id": "aa0e8400-e29b-41d4-a716-446655440000",
          "checkinId": "0f1c5a8e-4c6c-4a3b-9c48-2f4d1a0a3d11",
          "body": "Great spot",
          "createdAt": "2026-09-22T10:00:00.000Z",
          "user": { "id": "660e8400-e29b-41d4-a716-446655440000", "name": "Alex", "avatarUrl": null }
        }
        """
        let comment = try RankingFixtures.makeDecoder().decode(CheckinComment.self, from: Data(json.utf8))

        #expect(comment.body == "Great spot")
        #expect(comment.user.initials == "A")
    }

    @Test(
        "Decodes every kind of notification and says what happened",
        arguments: [
            ("like", "liked your checkin at Blue Bottle"),
            ("comment", "commented on your checkin at Blue Bottle: \u{201C}Great spot\u{201D}"),
            ("friend_request", "wants to be friends"),
            ("friend_accepted", "accepted your friend request"),
        ]
    )
    func decodesNotification(kind: String, summary: String) throws {
        let isAboutCheckin = kind == "like" || kind == "comment"
        let json = """
        {
          "results": [{
            "id": "bb0e8400-e29b-41d4-a716-446655440000",
            "kind": "\(kind)",
            "actor": { "id": "660e8400-e29b-41d4-a716-446655440000", "name": "Alex", "avatarUrl": null },
            "checkin": \(isAboutCheckin ? #"{ "id": "c1", "placeName": "Blue Bottle" }"# : "null"),
            "comment": \(kind == "comment" ? #"{ "id": "m1", "body": "Great spot" }"# : "null"),
            "friendship": \(isAboutCheckin ? "null" : #"{ "id": "f1", "status": "pending" }"#),
            "readAt": null,
            "createdAt": "2026-09-22T10:00:00.000Z"
          }],
          "unreadCount": 1
        }
        """
        let page = try RankingFixtures.makeDecoder().decode(NotificationsPage.self, from: Data(json.utf8))
        let notification = try #require(page.results.first)

        #expect(page.unreadCount == 1)
        #expect(notification.isUnread)
        #expect(notification.summaryText == summary)
        #expect(notification.actor.displayName == "Alex")
        if !isAboutCheckin {
            #expect(notification.friendship?.status == .pending)
        }
    }
}
