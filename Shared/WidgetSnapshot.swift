import Foundation

enum LocalFiles {
    static let group = "group.com.hgsldswk.daynoted"
    static let folder = "Daynoted"

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func widgetURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent("widget.json")
    }
}

struct WidgetSnapshot: Codable {
    var counts: [String: Int] = [:]
    var plusForever = false
    var plusFrom: Date?
    var plusUntil: Date?

    func hasPlus(at date: Date) -> Bool {
        if plusForever { return true }
        guard let plusFrom, let plusUntil else { return false }
        return date >= plusFrom && date < plusUntil
    }

    func count(_ day: Day) -> Int { counts[day.key, default: 0] }

    static func read() -> WidgetSnapshot {
        guard let url = LocalFiles.widgetURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return snapshot
    }
}

