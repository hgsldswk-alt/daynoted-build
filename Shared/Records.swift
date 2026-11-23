import Foundation

enum LogError: Error, Equatable {
    case empty, tooLong, invalidDate, missingEntry, storage, invalidBackup, invalidPreset, invalidExport

    var message: String {
        switch self {
        case .empty: return L.t("error.empty")
        case .tooLong: return L.t("error.length")
        case .invalidDate: return L.t("error.date")
        case .missingEntry: return L.t("error.missing")
        case .storage: return L.t("error.storage")
        case .invalidBackup: return L.t("error.backup")
        case .invalidPreset: return L.t("error.preset")
        case .invalidExport: return L.t("error.export")
        }
    }
}

struct DoneEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var dayKey: String
    let createdAt: Date
    var updatedAt: Date
    let captureTimeZone: String

    static func cleaned(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LogError.empty }
        guard value.count <= 240 else { throw LogError.tooLong }
        return value
    }

    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.dayKey != rhs.dayKey { return lhs.dayKey > rhs.dayKey }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct Draft: Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var dayKey: String
    var captureTimeZone: String

    init(day: Day, text: String = "", zone: TimeZone = .autoupdatingCurrent, id: UUID = UUID()) {
        self.id = id
        self.dayKey = day.key
        self.text = text
        self.captureTimeZone = zone.identifier
    }
}

struct ReviewProgress: Codable, Sendable {
    var firstRecordDay: String?
    var usedDays: Set<String> = []
    var ratingEligible = false
    var requestedVersions: Set<String> = []
    var dismissedMilestone = false

    mutating func record(on useDay: Day) {
        if firstRecordDay == nil { firstRecordDay = useDay.key }
        usedDays.insert(useDay.key)
        if usedDays.count >= 3 { ratingEligible = true }
    }

    func canRequest(version: String) -> Bool {
        ratingEligible && !requestedVersions.contains(version)
    }

    func hasMilestone(today: Day, entries: [DoneEntry]) -> Bool {
        guard let key = firstRecordDay, let first = Day(key: key),
              today.days(since: first) >= 6 else { return false }
        let weekStart = today.adding(-6).key
        return entries.contains { $0.dayKey >= weekStart && $0.dayKey <= today.key }
    }
}

enum CardLayout: String, Codable, CaseIterable, Sendable {
    case rows, bars, plain

    var isPlus: Bool { self != .rows }
    var title: String { L.t("layout." + rawValue) }

    func allowed(hasPlus: Bool) -> Self { isPlus && !hasPlus ? .rows : self }
}

enum Preset {
    private struct Payload: Codable {
        let layout: CardLayout
    }

    static func encode(_ layout: CardLayout) -> String {
        let data = (try? JSONEncoder().encode(Payload(layout: layout))) ?? Data()
        let base = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "DL1:" + base
    }

    static func decode(_ input: String) throws -> CardLayout {
        guard input.utf8.count <= 128 else { throw LogError.invalidPreset }
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = code.dropFirst(4)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        guard code.hasPrefix("DL1:"), !value.isEmpty, value.allSatisfy({ alphabet.contains($0) }) else {
            throw LogError.invalidPreset
        }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base.padding(toLength: ((base.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields.count == 1 else { throw LogError.invalidPreset }
        return payload.layout
    }
}

struct Backup: Codable, Sendable {
    static let limit = 64 * 1024 * 1024
    let version: Int
    let entries: [DoneEntry]

    static func export(_ entries: [DoneEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Backup(version: 1, entries: entries))
        guard data.count <= limit else { throw LogError.invalidExport }
        return data
    }

    static func load(_ data: Data) throws -> Backup {
        guard data.count <= limit, let backup = try? JSONDecoder().decode(Self.self, from: data),
              backup.version == 1 else { throw LogError.invalidBackup }
        var ids = Set<UUID>()
        for entry in backup.entries {
            guard ids.insert(entry.id).inserted,
                  let clean = try? DoneEntry.cleaned(entry.text), clean == entry.text,
                  Day(key: entry.dayKey) != nil, TimeZone(identifier: entry.captureTimeZone) != nil,
                  entry.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.updatedAt >= entry.createdAt else { throw LogError.invalidBackup }
        }
        return backup
    }

    func preview(against existing: [DoneEntry]) -> MergePreview {
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var result = MergePreview()
        for entry in entries {
            if let previous = byID[entry.id] {
                if previous == entry { result.skipped += 1 } else { result.conflicts += 1 }
            } else {
                result.additions.append(entry)
            }
        }
        return result
    }

    static func csv(_ entries: [DoneEntry]) -> Data {
        let formatter = ISO8601DateFormatter()
        let columns = ["csv.day", "csv.text", "csv.created", "csv.zone"].map { cell(L.t($0)) }
        let rows = entries.map { entry in
            [entry.dayKey, entry.text, formatter.string(from: entry.createdAt), entry.captureTimeZone].map(cell)
                .joined(separator: ",")
        }
        return Data(("\u{FEFF}" + ([columns.joined(separator: ",")] + rows).joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func cell(_ value: String) -> String {
        let significant = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let dangerous = significant.first.map { "=+-@＝＋－＠".contains($0) } ?? false
        let controlPrefix = value.first.map { $0 == "\t" || $0.isNewline } ?? false
        let safe = (dangerous || controlPrefix ? "'" : "") + value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct MergePreview: Sendable {
    var additions: [DoneEntry] = []
    var skipped = 0
    var conflicts = 0
}

