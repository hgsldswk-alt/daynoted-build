import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var unavailable = false
    @Published private(set) var entries: [DoneEntry] = []
    @Published private(set) var grouped: [String: [DoneEntry]] = [:]
    @Published private(set) var draft: Draft?
    @Published private(set) var editing: Draft?
    @Published private(set) var editorShown = false
    @Published private(set) var layout = CardLayout.rows
    @Published private(set) var progress = ReviewProgress()
    @Published private(set) var entitlement = Entitlement(firstOpen: Date())
    @Published private(set) var now = Date()
    @Published private(set) var today = Day(Date())
    @Published private(set) var busy = false
    @Published private(set) var deleted: DoneEntry?
    @Published var error: String?

    private var store: LogStore?
    private var draftWrite: Task<Void, Never>?

    var hasPlus: Bool {
        if Launch.expired { return false }
        return Launch.demoPro || entitlement.hasPro(at: now)
    }

    var week: [Day] { Day.range(from: today.adding(-6), through: today) }
    var todayEntries: [DoneEntry] { grouped[today.key] ?? [] }
    var milestone: Bool { progress.hasMilestone(today: today, entries: week.flatMap { grouped[$0.key] ?? [] }) }

    func start() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        updateClock()
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: false)
            let directory = base.appendingPathComponent(Launch.testing ? "Daynoted UITests" : LocalFiles.folder,
                                                        isDirectory: true)
            let storage = LogStore(directory: directory, now: now)
            let snapshot = try await storage.open(reset: Launch.reset, seed: Launch.seed ? Demo.entries(today: today, now: now) : [])
            store = storage
            apply(snapshot)
            entitlement = snapshot.state.entitlement
            draft = snapshot.state.draft
            editing = snapshot.state.editDraft
            editorShown = editing != nil
            unavailable = false
            ready = true
            await publishWidget()
        } catch {
            unavailable = true
            self.error = LogError.storage.message
        }
    }

    func tick() async {
        let oldDay = today
        let oldPlus = hasPlus
        updateClock()
        if oldDay != today || oldPlus != hasPlus { await publishWidget() }
    }

    func noteUseDay() async {
        guard let store, !progress.usedDays.contains(today.key) else { return }
        do { progress = try await store.visit(today) }
        catch { /* A later visit or save can retry. */ }
    }

    private func updateClock() {
        now = Date()
        today = Day(now)
    }

    func begin() {
        guard ready, draft == nil else { return }
        updateClock()
        let fixture = Launch.testing ? ProcessInfo.processInfo.environment["DAYNOTED_COMPOSE_TEXT"] : nil
        let value = Draft(day: today, text: fixture ?? "")
        draft = value
        persist(value)
    }

    func edit(_ entry: DoneEntry) {
        guard !busy else { return }
        if editing?.id == entry.id { editorShown = true; return }
        let value = Draft(day: Day(key: entry.dayKey) ?? today, text: entry.text,
                          zone: TimeZone(identifier: entry.captureTimeZone) ?? .current, id: entry.id)
        editing = value
        editorShown = true
        error = nil
        persist(value, editing: true)
    }

    func setText(_ text: String, editing isEdit: Bool = false) {
        guard !busy, var value = isEdit ? editing : draft, value.text != text else { return }
        value.text = text
        if isEdit { editing = value } else { draft = value }
        error = nil
        persist(value, editing: isEdit)
    }

    func setDay(_ day: Day, editing isEdit: Bool = false) {
        guard !busy, var value = isEdit ? editing : draft, value.dayKey != day.key, day <= today else { return }
        value.dayKey = day.key
        if isEdit { editing = value } else { draft = value }
        persist(value, editing: isEdit)
    }

    func closeEditorForNavigation() { editorShown = false }

    func cancel(editing isEdit: Bool = false) {
        guard !busy else { return }
        if isEdit {
            editing = nil
            editorShown = false
        } else { draft = nil }
        error = nil
        persist(nil, editing: isEdit)
    }

    func save(continuous: Bool = false, editing isEdit: Bool = false) async -> Bool {
        guard let store, !busy, let value = isEdit ? editing : draft else { return false }
        busy = true
        defer { busy = false }
        await draftWrite?.value
        updateClock()
        do {
            let snapshot: LogSnapshot
            if isEdit {
                snapshot = try await store.update(value, now: now, today: today)
                editing = nil
                editorShown = false
            } else {
                snapshot = try await store.add(value, now: now, today: today, continuous: continuous)
                draft = snapshot.state.draft
            }
            error = nil
            apply(snapshot)
            await publishWidget()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func deleteEditing() async {
        guard let id = editing?.id, let store, !busy else { return }
        busy = true
        defer { busy = false }
        await draftWrite?.value
        do {
            let (snapshot, entry) = try await store.remove(id)
            editing = nil
            editorShown = false
            deleted = entry
            error = nil
            apply(snapshot)
            await publishWidget()
        } catch { show(error) }
    }

    func undo() async {
        guard let entry = deleted else { return }
        let restored = await change({ try await $0.undo(entry) }, refreshWidget: true)
        if restored { deleted = nil }
    }

    func dismissUndo() { deleted = nil }

    func merge(_ backup: Backup) async -> Bool {
        await change({ try await $0.merge(backup) }, refreshWidget: true)
    }

    func selectLayout(_ layout: CardLayout) async -> Bool {
        await change { try await $0.changeLayout(layout) }
    }

    func dismissMilestone() async {
        _ = await change { try await $0.dismissMilestone() }
    }

    func claimReview(version: String) async -> Bool {
        guard let store, !busy else { return false }
        do {
            guard let snapshot = try await store.markReview(version: version) else { return false }
            progress = snapshot.state.progress
            return true
        } catch { return false }
    }

    func unclaimReview(version: String) async {
        guard let store else { return }
        if let latest = try? await store.unmarkReview(version: version) { progress = latest }
    }

    func recordStoreChange(_ change: @Sendable (inout Entitlement) -> Void) async throws {
        guard let store else { throw LogError.storage }
        entitlement = try await store.changeEntitlement(change)
        updateClock()
        await publishWidget()
    }

    func show(_ failure: Error) {
        error = (failure as? LogError ?? .storage).message
    }

    private func apply(_ snapshot: LogSnapshot) {
        if entries != snapshot.entries {
            entries = snapshot.entries
            grouped = snapshot.grouped
        }
        layout = snapshot.state.layout
        progress = snapshot.state.progress
    }

    private func persist(_ value: Draft?, editing: Bool = false) {
        guard let store else { return }
        let previous = draftWrite
        draftWrite = Task {
            await previous?.value
            do { try await store.saveDraft(value, editing: editing) }
            catch { show(error) }
        }
    }

    private func change(_ operation: (LogStore) async throws -> LogSnapshot, refreshWidget: Bool = false) async -> Bool {
        guard let store, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            apply(try await operation(store))
            error = nil
            if refreshWidget { await publishWidget() }
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func publishWidget() async {
        guard !Launch.testing, let store else { return }
        await store.publishWidget(today: today)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private enum Demo {
    static func entries(today: Day, now: Date) -> [DoneEntry] {
        let counts = [4, 3, 2, 0, 4, 2, 3]
        let samples = (1...8).map { L.t("demo.\($0)") }
        return counts.enumerated().flatMap { offset, count in
            (0..<count).map { index in
                let day = today.adding(-offset)
                let raw = Day.calendar().date(bySettingHour: 18 - index * 2, minute: index * 8, second: 0,
                                               of: day.date()) ?? now
                let time = min(raw, now.addingTimeInterval(-Double(index + 1) * 60))
                return DoneEntry(id: UUID(), text: samples[(offset * 3 + index) % samples.count], dayKey: day.key,
                                 createdAt: time, updatedAt: time, captureTimeZone: TimeZone.current.identifier)
            }
        }
    }
}

