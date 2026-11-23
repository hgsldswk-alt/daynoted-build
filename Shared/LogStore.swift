import Foundation
import SQLite3

struct LocalState: Codable, Sendable {
    var draft: Draft?
    var editDraft: Draft?
    var layout = CardLayout.rows
    var progress = ReviewProgress()
    var entitlement: Entitlement
}

struct LogSnapshot: Sendable {
    let state: LocalState
    let entries: [DoneEntry]
    let grouped: [String: [DoneEntry]]
}

actor LogStore {
    private let directory: URL
    private var database: OpaquePointer?
    private var state: LocalState
    private var entries: [UUID: DoneEntry] = [:]
    private var sorted: [DoneEntry] = []
    private var grouped: [String: [DoneEntry]] = [:]

    init(directory: URL, now: Date = Date()) {
        self.directory = directory
        self.state = LocalState(entitlement: Entitlement(firstOpen: now))
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func open(reset: Bool = false, seed: [DoneEntry] = []) throws -> LogSnapshot {
        if database != nil { return snapshot() }
        try LocalFiles.prepare(directory)
        let url = directory.appendingPathComponent("log.sqlite3")
        if reset, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close(opened) }
            throw LogError.storage
        }
        database = opened
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: url.path)
            try execute("CREATE TABLE IF NOT EXISTS local_state (id INTEGER PRIMARY KEY, data BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
            let states: [LocalState] = try read("SELECT data FROM local_state WHERE id=1")
            if let previous = states.first { state = previous }
            let records: [DoneEntry] = try read("SELECT data FROM entries")
            entries = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            sorted = records.sorted(by: DoneEntry.ordered)
            grouped = Dictionary(grouping: sorted, by: \.dayKey)
            if states.isEmpty {
                var initial = state
                if let first = seed.map(\.dayKey).min() { initial.progress.firstRecordDay = first }
                try commit(initial, writing: seed)
            }
            return snapshot()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw LogError.storage
        }
    }

    func saveDraft(_ draft: Draft?, editing: Bool = false) throws {
        var next = state
        if editing { next.editDraft = draft } else { next.draft = draft }
        try commit(next)
    }

    func add(_ draft: Draft, now: Date, today: Day, continuous: Bool) throws -> LogSnapshot {
        if entries[draft.id] != nil { return snapshot() }
        let text = try DoneEntry.cleaned(draft.text)
        guard let day = Day(key: draft.dayKey), day <= today else { throw LogError.invalidDate }
        let entry = DoneEntry(id: draft.id, text: text, dayKey: day.key, createdAt: now, updatedAt: now,
                              captureTimeZone: draft.captureTimeZone)
        var next = state
        next.draft = continuous ? Draft(day: today) : nil
        next.progress.record(on: today)
        try commit(next, writing: [entry])
        return snapshot()
    }

    func update(_ draft: Draft, now: Date, today: Day) throws -> LogSnapshot {
        guard var entry = entries[draft.id] else { throw LogError.missingEntry }
        guard let day = Day(key: draft.dayKey), day <= today else { throw LogError.invalidDate }
        entry.text = try DoneEntry.cleaned(draft.text)
        entry.dayKey = day.key
        entry.updatedAt = max(now, entry.createdAt)
        var next = state
        next.editDraft = nil
        try commit(next, writing: [entry])
        return snapshot()
    }

    func remove(_ id: UUID) throws -> (LogSnapshot, DoneEntry) {
        guard let entry = entries[id] else { throw LogError.missingEntry }
        var next = state
        next.editDraft = nil
        try commit(next, removing: id)
        return (snapshot(), entry)
    }

    func undo(_ entry: DoneEntry) throws -> LogSnapshot {
        if entries[entry.id] == nil { try commit(state, writing: [entry]) }
        return snapshot()
    }

    func merge(_ backup: Backup) throws -> LogSnapshot {
        try commit(state, writing: backup.preview(against: sorted).additions)
        return snapshot()
    }

    func changeLayout(_ layout: CardLayout) throws -> LogSnapshot {
        var next = state
        next.layout = layout
        try commit(next)
        return snapshot()
    }

    func dismissMilestone() throws -> LogSnapshot {
        var next = state
        next.progress.dismissedMilestone = true
        try commit(next)
        return snapshot()
    }

    func visit(_ day: Day) throws -> ReviewProgress {
        var next = state
        if next.progress.usedDays.insert(day.key).inserted { try commit(next) }
        return state.progress
    }

    func unmarkReview(version: String) throws -> ReviewProgress {
        var next = state
        if next.progress.requestedVersions.remove(version) != nil { try commit(next) }
        return state.progress
    }

    func markReview(version: String) throws -> LogSnapshot? {
        guard state.progress.canRequest(version: version) else { return nil }
        var next = state
        next.progress.requestedVersions.insert(version)
        try commit(next)
        return snapshot()
    }

    func changeEntitlement(_ change: @Sendable (inout Entitlement) -> Void) throws -> Entitlement {
        var next = state
        change(&next.entitlement)
        if next.entitlement != state.entitlement { try commit(next) }
        return next.entitlement
    }

    func publishWidget(today: Day) {
        guard let url = LocalFiles.widgetURL() else { return }
        let entitlement = state.entitlement
        var widget = WidgetSnapshot()
        let earliest = today.adding(-8).key
        let latest = today.adding(1).key
        for item in sorted where item.dayKey >= earliest && item.dayKey <= latest {
            widget.counts[item.dayKey, default: 0] += 1
        }
        widget.plusForever = Launch.freePeriod || entitlement.purchasedPro
        if entitlement.hasClaimed && !entitlement.trialRevoked {
            widget.plusFrom = entitlement.trialStart
            widget.plusUntil = entitlement.trialEnd
        }
        do {
            try LocalFiles.prepare(url.deletingLastPathComponent())
            try JSONEncoder().encode(widget).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
        }
    }

    private func snapshot() -> LogSnapshot { LogSnapshot(state: state, entries: sorted, grouped: grouped) }

    private func commit(_ next: LocalState, writing changed: [DoneEntry] = [], removing id: UUID? = nil) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if let id {
                try statement("DELETE FROM entries WHERE id=?") { handle in
                    try bind(id.uuidString, to: handle)
                    guard sqlite3_step(handle) == SQLITE_DONE else { throw LogError.storage }
                }
            }
            if !changed.isEmpty {
                try statement("INSERT OR REPLACE INTO entries (id,data) VALUES (?,?)") { handle in
                    for entry in changed {
                        try bind(entry.id.uuidString, to: handle)
                        try write(entry, to: handle, index: 2)
                        sqlite3_reset(handle)
                        sqlite3_clear_bindings(handle)
                    }
                }
            }
            try statement("INSERT OR REPLACE INTO local_state (id,data) VALUES (1,?)") {
                try write(next, to: $0, index: 1)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw LogError.storage
        }
        state = next
        if let id { entries.removeValue(forKey: id) }
        for entry in changed { entries[entry.id] = entry }
        if id != nil || !changed.isEmpty {
            sorted = entries.values.sorted(by: DoneEntry.ordered)
            grouped = Dictionary(grouping: sorted, by: \.dayKey)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw LogError.storage }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw LogError.storage }
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            throw LogError.storage
        }
        defer { sqlite3_finalize(handle) }
        return try body(handle)
    }

    private func read<T: Decodable>(_ sql: String) throws -> [T] {
        try statement(sql) { handle in
            var values: [T] = []
            let decoder = JSONDecoder()
            while true {
                switch sqlite3_step(handle) {
                case SQLITE_DONE: return values
                case SQLITE_ROW:
                    guard let bytes = sqlite3_column_blob(handle, 0) else { throw LogError.storage }
                    values.append(try decoder.decode(T.self,
                        from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, 0)))))
                default: throw LogError.storage
                }
            }
        }
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func bind(_ value: String, to handle: OpaquePointer) throws {
        let result = value.withCString { sqlite3_bind_text(handle, 1, $0, -1, transient) }
        guard result == SQLITE_OK else { throw LogError.storage }
    }

    private func write<T: Encodable>(_ value: T, to handle: OpaquePointer, index: Int32) throws {
        let data = try JSONEncoder().encode(value)
        let result = data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient) }
        guard result == SQLITE_OK, sqlite3_step(handle) == SQLITE_DONE else { throw LogError.storage }
    }
}

