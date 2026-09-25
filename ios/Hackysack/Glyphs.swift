//
//  Glyphs.swift
//  Hackysack
//

/// Every SF Symbol the app draws, named for what it means here rather than
/// what it looks like, so swapping an icon is a one-line change and two uses
/// that merely share a picture today can diverge tomorrow.
///
///     Label(hometown, systemImage: Glyphs.hometown)
///
/// Plain strings because SF Symbols have no generated constants; a name that
/// doesn't exist draws nothing rather than failing to build, so check new
/// ones in the SF Symbols app.
///
/// nonisolated so non-UI code, like the place type mapping, can read it.
nonisolated enum Glyphs {
    // MARK: Tabs

    static let timelineTab = "clock"
    static let friendsTab = "person.2"
    static let profileTab = "person.crop.circle"

    // MARK: Brand

    /// The mark above the app name on the welcome screen.
    static let appLogo = "mappin.and.ellipse"

    // MARK: Checkins

    static let changeLocation = "mappin.and.ellipse"
    /// "Visited 3 times" under a nearby place.
    static let visitedBefore = "checkmark.circle"
    static let privateCheckin = "lock.fill"
    static let friendsCheckin = "person.2.fill"
    static let retryCheckin = "arrow.clockwise"
    static let noCheckins = "mappin.and.ellipse"
    static let noPlacesNearby = "mappin.slash"
    /// Someone's checkins, hidden until you're friends.
    static let friendsOnly = "lock.fill"

    // MARK: Place types

    static let placeDefault = "mappin"
    static let placeCafe = "cup.and.saucer.fill"
    static let placeBar = "wineglass.fill"
    static let placePark = "tree.fill"
    static let placeGym = "dumbbell.fill"
    static let placeStore = "bag.fill"
    static let placeTheater = "theatermasks.fill"
    static let placeMuseum = "building.columns.fill"
    static let placeHotel = "bed.double.fill"
    static let placeTransit = "tram.fill"
    static let placeRestaurant = "fork.knife"

    // MARK: Profile

    static let hometown = "house.fill"
    static let settings = "gearshape"
    /// The badge on the avatar in Edit Profile.
    static let editPhoto = "camera.fill"
    static let choosePhoto = "photo.on.rectangle"
    static let chooseFile = "folder"
    static let currentLocation = "location.fill"

    // MARK: Friends

    static let addFriend = "person.badge.plus"
    /// On the Friends button on a friend's profile, which offers to remove them.
    static let friendOptions = "chevron.down"
    static let noFriends = "person.2"
    static let findFriends = "person.crop.circle.badge.plus"
    static let search = "magnifyingglass"

    // MARK: General

    static let disclosure = "chevron.right"
    /// A screen whose content couldn't load.
    static let loadError = "exclamationmark.triangle"
    /// An inline error under a form.
    static let formError = "exclamationmark.circle.fill"

    // MARK: General actions

    static let add = "plus"
    static let camera = "camera"
    static let delete = "trash"
    static let accept = "checkmark"
    static let reject = "xmark"
    /// A plain checkmark shown as a status, not tied to an accept/confirm action.
    static let checkmark = "checkmark"

    // MARK: Debug

    static let debugMenu = "ladybug"
    static let debugVisitHere = "mappin.and.ellipse"
    static let debugBackfillVisits = "clock.arrow.circlepath"
}
