import CoreImage
import ImageIO
import UIKit
import SQLite3
import XCTest

final class CoreTests: XCTestCase {
    func testDayGroupingAndCalendarBoundaries() throws {
        let west = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let east = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:55:00Z"))
        XCTAssertEqual(Day(timestamp, zone: west).key, "2026-03-07")
        XCTAssertEqual(Day(timestamp, zone: east).key, "2026-03-08")
        let spring = try day("2026-03-08")
        let fall = try day("2026-11-01")
        XCTAssertEqual(spring.adding(1).days(since: spring), 1)
        XCTAssertEqual(fall.adding(1).days(since: fall), 1)
        XCTAssertEqual(try day("2024-02-29").adding(1).key, "2024-03-01")
        XCTAssertEqual(try day("2026-01-31").adding(1).key, "2026-02-01")
        XCTAssertEqual(Day.range(from: spring.adding(-6), through: spring).count, 7)
        XCTAssertNil(Day(key: "2026-02-29"))
        XCTAssertNil(Day(key: "2026-1-01"))
    }

    func testUnicodeLengthAndCommittedText() throws {
        let characters = String(repeating: "👩🏽‍💻", count: 240)
        XCTAssertEqual(try DoneEntry.cleaned(" \n" + characters + "\t "), characters)
        XCTAssertEqual(try DoneEntry.cleaned("  确认候选后保存  "), "确认候选后保存")
        XCTAssertThrowsError(try DoneEntry.cleaned(characters + "字"))
        XCTAssertThrowsError(try DoneEntry.cleaned("　 \n"))
    }

    func testDraftRecoveryMidnightDuplicateEditDeleteAndUndo() async throws {
        let location = temporaryStore()
        defer { try? FileManager.default.removeItem(at: location) }
        let before = try day("2026-11-23")
        let after = before.adding(1)
        let now = after.date(in: Day.utc)
        let west = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let draft = Draft(day: before, text: "Completed the handoff", zone: west)
        let first = LogStore(directory: location, now: now)
        _ = try await first.open()
        try await first.saveDraft(draft)

        let store = LogStore(directory: location, now: now)
        let recovered = try await store.open()
        XCTAssertEqual(recovered.state.draft, draft)
        let saved = try await store.add(draft, now: now, today: after, continuous: true)
        XCTAssertEqual(saved.entries.first?.dayKey, before.key)
        XCTAssertEqual(saved.entries.first?.captureTimeZone, west.identifier)
        XCTAssertEqual(saved.state.draft?.dayKey, after.key)
        XCTAssertEqual(saved.state.draft?.text, "")
        let duplicate = try await store.add(draft, now: now, today: after, continuous: false)
        XCTAssertEqual(duplicate.entries.count, 1)
        let sameText = Draft(day: after, text: draft.text)
        let repeated = try await store.add(sameText, now: now, today: after, continuous: false)
        XCTAssertEqual(repeated.entries.count, 2)

        var correction = draft
        correction.dayKey = after.key
        correction.text = "Finished the handoff"
        let corrected = try await store.update(correction, now: now.addingTimeInterval(10), today: after)
        XCTAssertEqual(corrected.entries.first(where: { $0.id == draft.id })?.text, correction.text)
        XCTAssertTrue(corrected.entries.allSatisfy { $0.dayKey == after.key })
        let (removed, entry) = try await store.remove(draft.id)
        XCTAssertEqual(removed.entries.count, 1)
        let restored = try await store.undo(entry)
        XCTAssertEqual(restored.entries, corrected.entries)
    }

    func testFailedTransactionLeavesPreviousDraftOnDisk() async throws {
        let location = temporaryStore()
        defer { try? FileManager.default.removeItem(at: location) }
        let now = Date()
        let today = Day(now)
        let store = LogStore(directory: location, now: now)
        _ = try await store.open()
        let draft = Draft(day: today, text: "Kept after failure")
        try await store.saveDraft(draft)

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(location.appendingPathComponent("log.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do {
            _ = try await store.add(draft, now: now, today: today, continuous: false)
            XCTFail("A competing writer should prevent the transaction")
        } catch {
            XCTAssertEqual(error as? LogError, .storage)
        }
        XCTAssertEqual(sqlite3_exec(connection, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        let reopened = LogStore(directory: location)
        let snapshot = try await reopened.open()
        XCTAssertEqual(snapshot.state.draft, draft)
        XCTAssertTrue(snapshot.entries.isEmpty)
        let retry = try await reopened.add(draft, now: now, today: today, continuous: false)
        XCTAssertNil(retry.state.draft)
        XCTAssertEqual(retry.entries.map(\.text), [draft.text])
    }

    func testBackupValidationConflictsAndSpreadsheetEscaping() async throws {
        let location = temporaryStore()
        defer { try? FileManager.default.removeItem(at: location) }
        let now = Date()
        let today = Day(now)
        let store = LogStore(directory: location)
        _ = try await store.open()
        let draft = Draft(day: today, text: "=SUM(1,2)\n\"原文\"")
        let saved = try await store.add(draft, now: now, today: today, continuous: false)
        let original = try XCTUnwrap(saved.entries.first)
        let roundTrip = try Backup.load(Backup.export([original]))
        XCTAssertEqual(roundTrip.preview(against: saved.entries).skipped, 1)

        var collision = original
        collision.text = "Different text"
        let other = DoneEntry(id: UUID(), text: "Lowered the blinds", dayKey: today.key,
                              createdAt: now, updatedAt: now, captureTimeZone: "GMT")
        let backup = try Backup.load(Backup.export([collision, other]))
        let preview = backup.preview(against: saved.entries)
        XCTAssertEqual(preview.additions, [other])
        XCTAssertEqual(preview.conflicts, 1)
        let merged = try await store.merge(backup)
        XCTAssertEqual(merged.entries.count, 2)
        XCTAssertTrue(merged.entries.contains(original))
        XCTAssertThrowsError(try Backup.load(Backup.export([other, other])))

        let csv = String(decoding: Backup.csv([original]), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\n\"\"原文\"\"\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testEntitlementRequiresVerifiedTrialAndKeepsOriginalDate() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let end = start.addingTimeInterval(Entitlement.duration)
        var state = Entitlement(firstOpen: start.addingTimeInterval(-30))
        XCTAssertFalse(state.hasPro(at: start))
        state.proStartedAt = start
        state.trialTransactionID = 21
        XCTAssertFalse(state.hasPro(at: start.addingTimeInterval(-1)))
        XCTAssertTrue(state.hasPro(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(state.hasPro(at: end))
        state.firstOpen = end
        XCTAssertFalse(state.hasPro(at: end), "Reinstallation must not restart the original trial")
        state.trialRevoked = true
        XCTAssertFalse(state.hasPro(at: start))
        state.proTransactionID = 42
        XCTAssertTrue(state.hasPro(at: end.addingTimeInterval(1)))
        state.proTransactionID = nil
        XCTAssertFalse(state.hasPro(at: end))
        XCTAssertTrue(state.hasPro(at: end, free: true))
        XCTAssertFalse(Launch.freePeriod)
    }

    func testPresetQRCodeAndMilestone() throws {
        for layout in CardLayout.allCases { XCTAssertEqual(try Preset.decode(Preset.encode(layout)), layout) }
        XCTAssertThrowsError(try Preset.decode("DL2:abc"))
        XCTAssertThrowsError(try Preset.decode("DL1:" + String(repeating: "a", count: 130)))
        XCTAssertThrowsError(try Preset.decode("DL1:eyJsYXlvdXQiOiJ1bmtub3duIn0"))
        XCTAssertEqual(CardLayout.bars.allowed(hasPlus: false), .rows)
        let address = DownloadCode.address(storeID: "1234567890")
        let image = try XCTUnwrap(DownloadCode.image(for: address))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let code = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(code, [address])
        XCTAssertEqual(DownloadCode.address(storeID: ""), "https://hgsldswk-alt.github.io/daynoted-support/")

        let first = try day("2026-11-01")
        let today = first.adding(6)
        let entry = DoneEntry(id: UUID(), text: "Kept going", dayKey: today.key, createdAt: Date(),
                              updatedAt: Date(), captureTimeZone: "GMT")
        var progress = ReviewProgress()
        progress.record(on: first)
        progress.record(on: first)
        progress.usedDays.insert(first.adding(1).key)
        progress.usedDays.insert(first.adding(2).key)
        XCTAssertFalse(progress.canRequest(version: "1.0"))
        progress.record(on: today)
        XCTAssertTrue(progress.canRequest(version: "1.0"))
        progress.requestedVersions.insert("1.0")
        XCTAssertFalse(progress.canRequest(version: "1.0"))
        XCTAssertTrue(progress.canRequest(version: "1.1"))
        XCTAssertFalse(progress.hasMilestone(today: first.adding(5), entries: [entry]))
        XCTAssertTrue(progress.hasMilestone(today: today, entries: [entry]))
        XCTAssertFalse(progress.hasMilestone(today: today.adding(7), entries: [entry]))
    }

func testFullShareCardDimensionsPrivacyAndDownloadCode() async throws {
        let current = try day("2026-11-24")
        let now = current.date(in: Day.utc)
        let first = DoneEntry(id: UUID(), text: String(repeating: "只在明确选中后显示。", count: 21),
                              dayKey: current.key, createdAt: now, updatedAt: now, captureTimeZone: "GMT")
        let second = DoneEntry(id: UUID(), text: String(repeating: "a private entry ", count: 15),
                               dayKey: current.key, createdAt: now, updatedAt: now, captureTimeZone: "GMT")
        let range = ShareRange(kind: .week, days: Day.range(from: current.adding(-6), through: current))
        let entries = [current.key: [first, second]]
        let privateCard = CardContent(range: range, entries: entries, layout: .rows, placeholderQR: false)
        XCTAssertTrue(privateCard.excerpts.isEmpty)
        XCTAssertEqual(privateCard.counts, [0, 0, 0, 0, 0, 0, 2])
        let selected = CardContent(range: range, entries: entries, selected: [first.id, second.id],
                                   layout: .bars, placeholderQR: false)
        XCTAssertEqual(selected.excerpts, [first.text, second.text])

        let address = DownloadCode.address(storeID: "1234567890")
        let qr = try XCTUnwrap(DownloadCode.image(for: address))
        let rendered = await MainActor.run { ShareArtwork.render(selected, qr: qr)?.cgImage }
        let image = try XCTUnwrap(rendered)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1350)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(codes, [address])

        let url = try ShareFile.write(image)
        defer { ShareFile.remove(url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary as String])
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil(exif?[kCGImagePropertyExifLensModel as String])
    }

    private func day(_ key: String) throws -> Day { try XCTUnwrap(Day(key: key)) }

    private func temporaryStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
