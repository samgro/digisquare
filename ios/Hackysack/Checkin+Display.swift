//
//  Checkin+Display.swift
//  Hackysack
//

import Foundation

enum RelativeDay {
    /// "Today", "Yesterday", a weekday name for the rest of the past week, or
    /// "Tuesday, Sep 12" beyond that, with the year added ("Tuesday, Sep 12,
    /// 2025") only when it isn't the current one. Without the weekday, dates
    /// beyond the past week read "Sep 12" or "Sep 12, 2025".
    static func label(
        for date: Date,
        includesWeekday: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let startOfDay = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        if let daysAgo = calendar.dateComponents([.day], from: startOfDay, to: startOfNow).day,
           daysAgo > 0, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        let monthAndDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let dayFormat = includesWeekday ? monthAndDay.weekday(.wide) : monthAndDay
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(dayFormat)
        }
        return date.formatted(dayFormat.year())
    }
}

extension Checkin {
    /// The city, as the API stored it with the checkin. Rows saved before the
    /// API kept it separately fall back to the second comma-separated part of
    /// the address line: "450 10th St, San Francisco, CA 94103, US" →
    /// "San Francisco". Returns `nil` when neither is available.
    var locality: String? {
        if let placeLocality {
            let trimmed = placeLocality.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let placeAddress else { return nil }
        let components = placeAddress.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count > 1 else { return nil }
        let trimmed = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Coffee Shop": the place's own label when the source gave one (a
    /// Swarm import keeps Foursquare's), else the Overture category's name.
    var categoryName: String? {
        placeCategoryName ?? placePrimaryType.map { PlaceTypeSymbol.displayName(for: $0) }
    }

    /// Where the checkin happened, when known, so history reads in local time:
    /// a dinner in Tokyo shows 7 PM, not whatever the time was back home.
    var timeZone: TimeZone {
        timeZoneOffsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? .current
    }

    /// The calendar day the checkin happened on, where it happened, as the
    /// start of that day in `calendar`, so it can be grouped and compared
    /// with "today" here.
    func localDay(in calendar: Calendar = .current) -> Date {
        var checkinCalendar = calendar
        checkinCalendar.timeZone = timeZone
        let components = checkinCalendar.dateComponents([.year, .month, .day], from: createdAt)
        return calendar.date(from: components) ?? calendar.startOfDay(for: createdAt)
    }

    /// Just the time, "7:12 PM", in the checkin's local time, for rows that
    /// sit under a day header.
    var formattedCheckinTime: String {
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = timeZone
        return createdAt.formatted(timeStyle)
    }

    /// "Today · 7:12 PM", "Yesterday · 7:12 PM", "Thursday · 7:12 PM" within
    /// the past week, or "Sep 12 · 7:12 PM" further back, for rows with no day
    /// header above them. The day is the one where the checkin happened.
    var formattedCheckinDateAndTime: String {
        let day = RelativeDay.label(for: localDay(), includesWeekday: false)
        return "\(day) · \(formattedCheckinTime)"
    }
}
