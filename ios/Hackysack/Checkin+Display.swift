//
//  Checkin+Display.swift
//  Hackysack
//

import Foundation

enum RelativeDay {
    /// "Today", "Yesterday", a weekday name for the rest of the past week, or a
    /// numeric date beyond that.
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let startOfDay = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        if let daysAgo = calendar.dateComponents([.day], from: startOfDay, to: startOfNow).day,
           daysAgo > 0, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
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

    /// "7:12 PM" today, "Yesterday 7:12 PM", "Thursday 7:12 PM" within the past
    /// week, or "8/12/2026 7:12 PM" further back.
    var formattedCheckinTime: String {
        let time = createdAt.formatted(date: .omitted, time: .shortened)
        guard !Calendar.current.isDateInToday(createdAt) else { return time }
        return "\(RelativeDay.label(for: createdAt)) \(time)"
    }
}
