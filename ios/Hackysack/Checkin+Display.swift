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
    /// The city/locality portion of the Google formatted address, e.g.
    /// "450 10th St, San Francisco, CA 94103, USA" → "San Francisco". Returns
    /// `nil` when there's no address or no second comma-separated component.
    var locality: String? {
        guard let placeAddress else { return nil }
        let components = placeAddress.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count > 1 else { return nil }
        let trimmed = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Just the time, "7:12 PM", for rows that sit under a day header.
    var formattedCheckinTime: String {
        createdAt.formatted(date: .omitted, time: .shortened)
    }

    /// "Today · 7:12 PM", "Yesterday · 7:12 PM", "Thursday · 7:12 PM" within
    /// the past week, or "Sep 12 · 7:12 PM" further back, for rows with no day
    /// header above them.
    var formattedCheckinDateAndTime: String {
        let day = RelativeDay.label(for: createdAt, includesWeekday: false)
        return "\(day) · \(formattedCheckinTime)"
    }
}

extension VisitRecord {
    /// "2:15 – 5:40 PM" for a completed stay, or "Arrived 2:15 PM" while the
    /// user is still there, for rows that sit under a day header.
    var formattedSpan: String {
        let arrival = arrivalDate.formatted(date: .omitted, time: .shortened)
        guard let departureDate else {
            return "Arrived \(arrival)"
        }
        let departure = departureDate.formatted(date: .omitted, time: .shortened)
        return "\(arrival) – \(departure)"
    }

    /// "Yesterday · 2:15 – 5:40 PM", like `Checkin.formattedCheckinDateAndTime`,
    /// for rows with no day header above them.
    var formattedDateAndSpan: String {
        let day = RelativeDay.label(for: arrivalDate, includesWeekday: false)
        return "\(day) · \(formattedSpan)"
    }
}
