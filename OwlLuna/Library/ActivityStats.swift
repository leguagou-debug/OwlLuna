import Foundation

/// Counts and calendar layout over the writing log.
enum ActivityStats {
    /// The month as weeks starting on the calendar's first weekday: 35 or 42 cells, nil outside the month.
    static func monthGrid(containing date: Date, calendar: Calendar) -> [Date?] {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let length = calendar.range(of: .day, in: .month, for: date)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<length { cells.append(calendar.date(byAdding: .day, value: offset, to: month.start)) }
        let total = max(35, Int((Double(cells.count) / 7).rounded(.up)) * 7)
        return cells + Array(repeating: nil, count: total - cells.count)
    }

    /// Notebooks since deleted count their pages but not themselves.
    static func totals(for key: String, in log: ActivityLog) -> (pages: Int, notebooks: Int) {
        guard let day = log.days[key] else { return (0, 0) }
        return (day.pageCount, day.notebooks.values.count(where: { !$0.isEmpty }))
    }

    static func totals(in interval: DateInterval, log: ActivityLog, calendar: Calendar) -> (pages: Int, days: Int) {
        let inside = keyFilter(interval, calendar: calendar)
        let pages = log.days.filter { inside($0.key) }.map(\.value.pageCount).filter { $0 > 0 }
        return (pages.reduce(0, +), pages.count)
    }

    /// Whether a day key falls in `interval`: from its first day up to, not including, the day it ends on.
    private static func keyFilter(_ interval: DateInterval, calendar: Calendar) -> (String) -> Bool {
        let start = ActivityFile.dayKey(for: interval.start, calendar: calendar)
        let end = ActivityFile.dayKey(for: interval.end, calendar: calendar)
        return { $0 >= start && $0 < end }
    }

    static func yearTotals(year: Int, in log: ActivityLog, calendar: Calendar) -> (pages: Int, days: Int) {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let interval = calendar.dateInterval(of: .year, for: start) else { return (0, 0) }
        return totals(in: interval, log: log, calendar: calendar)
    }

    /// The most consecutive days with writing, optionally only counting days inside `interval`.
    static func longestRun(in log: ActivityLog, calendar: Calendar, within interval: DateInterval? = nil) -> Int {
        let inside = interval.map { keyFilter($0, calendar: calendar) }
        let written = Set(log.days.filter { key, day in
            day.pageCount > 0 && inside.map { $0(key) } ?? true
        }.keys)
        func next(_ key: String, by days: Int) -> String? {
            ActivityFile.date(forKey: key, calendar: calendar)
                .flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
                .map { ActivityFile.dayKey(for: $0, calendar: calendar) }
        }
        var longest = 0
        for key in written where next(key, by: -1).map(written.contains) != true {
            var length = 1
            var cursor = key
            while let following = next(cursor, by: 1), written.contains(following) {
                length += 1
                cursor = following
            }
            longest = max(longest, length)
        }
        return longest
    }
}
