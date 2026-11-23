import Foundation

struct Day: Hashable, Comparable, Sendable {
    let key: String

    init(_ date: Date, zone: TimeZone = .autoupdatingCurrent) {
        let parts = Self.calendar(zone).dateComponents([.year, .month, .day], from: date)
        key = String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    init?(key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, key.utf8.count == 10,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...9999).contains(y), (1...12).contains(m), (1...31).contains(d),
              let date = Self.calendar(Self.utc).date(from: DateComponents(year: y, month: m, day: d)),
              Day(date, zone: Self.utc).key == key else { return nil }
        self.key = key
    }

    static let utc = TimeZone(secondsFromGMT: 0)!

    static func calendar(_ zone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    func date(in zone: TimeZone = .autoupdatingCurrent) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return Self.calendar(zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    func adding(_ distance: Int) -> Day {
        let date = Self.calendar(Self.utc).date(byAdding: .day, value: distance, to: date(in: Self.utc))!
        return Day(date, zone: Self.utc)
    }

    func days(since earlier: Day) -> Int {
        Self.calendar(Self.utc).dateComponents([.day], from: earlier.date(in: Self.utc), to: date(in: Self.utc)).day ?? 0
    }

    var monthStart: Day { Day(key: String(key.prefix(7)) + "-01")! }

    func formatted(_ style: Date.FormatStyle) -> String {
        var configured = style
        configured.timeZone = Self.utc
        return date(in: Self.utc).formatted(configured)
    }

    static func < (lhs: Day, rhs: Day) -> Bool { lhs.key < rhs.key }

    static func range(from first: Day, through last: Day) -> [Day] {
        guard first <= last else { return [] }
        return (0...last.days(since: first)).map { last.adding(-$0) }
    }
}

