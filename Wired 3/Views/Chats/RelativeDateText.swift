//
//  RelativeDateText.swift
//  Wired 3
//
//  Created by Codex on 19/03/2026.
//

import Foundation
import SwiftUI

struct RelativeDateText: View {
    let date: Date

    var body: some View {
        if #available(macOS 15.0, *) {
            Text(.currentDate, format: .reference(to: date))
        } else {
            TimelineView(RelativeDateTimelineSchedule(referenceDate: date)) { context in
                Text(Self.formattedString(for: date, relativeTo: context.date))
            }
        }
    }

    private static func formattedString(for date: Date, relativeTo referenceDate: Date) -> String {
        let elapsed = abs(referenceDate.timeIntervalSince(date))

        if elapsed < 60 {
            return relativeFormatter.localizedString(fromTimeInterval: 0)
        }

        return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private static var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }
}

private struct RelativeDateTimelineSchedule: TimelineSchedule {
    let referenceDate: Date

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(currentDate: startDate, referenceDate: referenceDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        var currentDate: Date
        let referenceDate: Date

        mutating func next() -> Date? {
            let nextDate = RelativeDateTimelineSchedule.nextUpdateDate(
                after: currentDate,
                relativeTo: referenceDate
            )
            currentDate = nextDate
            return nextDate
        }
    }

    private static func nextUpdateDate(after currentDate: Date, relativeTo referenceDate: Date) -> Date {
        let offset = currentDate.timeIntervalSince(referenceDate)
        let direction: TimeInterval = offset >= 0 ? 1 : -1
        let elapsed = abs(offset)

        let nextBoundary: TimeInterval
        switch elapsed {
        case ..<60:
            nextBoundary = 60
        case ..<3600:
            nextBoundary = (floor(elapsed / 60) + 1) * 60
        case ..<86_400:
            nextBoundary = (floor(elapsed / 3600) + 1) * 3600
        default:
            nextBoundary = (floor(elapsed / 86_400) + 1) * 86_400
        }

        return referenceDate.addingTimeInterval(nextBoundary * direction)
    }
}
