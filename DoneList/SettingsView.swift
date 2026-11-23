import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    var paywall: () -> Void
    @State private var importedLayout: CardLayout?
    @State private var pendingBackup: PendingBackup?
    @State private var exporting = false
    @State private var importing = false
    @State private var transferring = false
    @State private var document: LocalDocument?
    @State private var status: String?
    @State private var testExport: String?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: L.t("settings.title")) {
                    ActionButton(title: L.t("common.done"), id: "settings.done", action: close)
                }
                presets
                files
                if !Launch.freePeriod || Launch.testing {
                    ActionButton(title: L.t("paywall.title"), id: "settings.plus", style: .bordered, action: paywall)
                }
            }
            .padding(20)
        }
        .pageSurface()
        .fileExporter(isPresented: $exporting, document: document, contentType: document?.type ?? .json,
                      defaultFilename: document?.name) { result in
            switch result {
            case .success: status = L.t("backup.exported")
            case .failure: failure = LogError.invalidExport.message
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { openBackup(url) }
            else if case .failure = result { failure = LogError.invalidBackup.message }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("preset.title")).font(.headline)
            Text(L.t("preset.help")).font(.footnote).foregroundStyle(Palette.muted)
            ActionButton(title: L.t("preset.copy"), id: "preset.copy", style: .bordered) {
                UIPasteboard.general.string = Preset.encode(model.layout.allowed(hasPlus: model.hasPlus))
                status = L.t("common.copied")
            }
            if Launch.testing, let fixture = ProcessInfo.processInfo.environment["DAYNOTED_PRESET"] {
                ActionButton(title: L.t("preset.paste"), id: "preset.paste", style: .bordered) { decodePreset(fixture) }
            } else {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { decodePreset(text) }
                }
                .labelStyle(.titleAndIcon)
                .tint(Palette.accentText)
                .frame(minHeight: 44)
                .accessibilityLabel(L.t("preset.paste"))
                .accessibilityIdentifier("preset.paste")
            }
            if let importedLayout {
                let effective = importedLayout.allowed(hasPlus: model.hasPlus)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("preset.preview")).font(.headline)
                    Text(L.format("preset.layout", effective.title))
                    Text(L.t("share.private")).font(.footnote).foregroundStyle(Palette.muted)
                    if effective != importedLayout {
                        Text(L.t("preset.fallback")).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    HStack {
                        ActionButton(title: L.t("preset.apply"), id: "preset.apply", style: .primary) {
                            Task {
                                if await model.selectLayout(effective) {
                                    self.importedLayout = nil
                                    status = L.t("preset.applied")
                                } else { failure = model.error }
                            }
                        }
                        ActionButton(title: L.t("common.cancel"), id: "preset.cancel") { self.importedLayout = nil }
                    }
                }
                .padding(10).panel(Palette.tint)
            }
        }
        .padding(13).panel()
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("backup.title")).font(.headline)
            ActionButton(title: L.t("backup.export"), id: "backup.export", style: .bordered) { export(csv: false) }
                .disabled(transferring)
            ActionButton(title: L.t("backup.import"), id: "backup.import", style: .bordered) {
                failure = nil
                status = nil
                if Launch.testing, let fixture = ProcessInfo.processInfo.environment["DAYNOTED_BACKUP"] {
                    prepare({ Data(fixture.utf8) })
                } else { importing = true }
            }
            .disabled(transferring)
            ActionButton(title: L.t("backup.csv"), id: "backup.csv", style: .bordered,
                         icon: model.hasPlus ? nil : "lock") {
                if model.hasPlus { export(csv: true) } else { paywall() }
            }
            .disabled(transferring)
            if let backup = pendingBackup { mergePreview(backup) }
            if let status { Text(status).font(.footnote).accessibilityIdentifier("settings.status") }
            if let testExport { Text(testExport).font(.footnote).accessibilityIdentifier("export.requested") }
            ErrorLine(text: failure)
        }
        .padding(13).panel()
    }

    private func mergePreview(_ backup: PendingBackup) -> some View {
        let summary = backup.summary
        return VStack(alignment: .leading, spacing: 6) {
            Text(L.t("backup.preview")).font(.headline)
            Text(L.format("backup.summary", summary.additions.count, summary.skipped, summary.conflicts))
                .font(.subheadline).accessibilityIdentifier("backup.summary")
            HStack {
                ActionButton(title: L.t("backup.merge"), id: "backup.merge", style: .primary) {
                    Task {
                        if await model.merge(backup.file) {
                            pendingBackup = nil
                            status = L.t("backup.merged")
                        } else { failure = model.error }
                    }
                }
                .disabled(model.busy)
                ActionButton(title: L.t("common.cancel"), id: "backup.cancel") { pendingBackup = nil }
                    .disabled(model.busy)
            }
        }
        .padding(10).panel(Palette.tint)
    }

    private func decodePreset(_ value: String) {
        failure = nil
        status = nil
        do { importedLayout = try Preset.decode(value) }
        catch {
            importedLayout = nil
            failure = LogError.invalidPreset.message
        }
    }

    private func export(csv: Bool) {
        let entries = model.entries
        failure = nil
        status = nil
        transferring = true
        Task {
            defer { transferring = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    if csv { return Backup.csv(entries) }
                    return try Backup.export(entries)
                }.value
                if Launch.testing { testExport = L.t(csv ? "backup.csv" : "backup.export") }
                else {
                    document = LocalDocument(data: data, type: csv ? .commaSeparatedText : .json,
                        name: csv ? "Daynoted.csv" : "Daynoted-backup.json")
                    exporting = true
                }
            } catch { failure = LogError.invalidExport.message }
        }
    }

    private func openBackup(_ url: URL) {
        prepare {
            let accessible = url.startAccessingSecurityScopedResource()
            defer { if accessible { url.stopAccessingSecurityScopedResource() } }
            var error: NSError?
            var data: Result<Data, Error> = .failure(LogError.invalidBackup)
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { path in
                data = Result {
                    let file = try FileHandle(forReadingFrom: path)
                    defer { try? file.close() }
                    var buffer = Data()
                    while buffer.count <= Backup.limit,
                          let part = try file.read(upToCount: min(1024 * 1024, Backup.limit + 1 - buffer.count)),
                          !part.isEmpty {
                        buffer.append(part)
                    }
                    return buffer
                }
            }
            if let error { throw error }
            return try data.get()
        }
    }

    private func prepare(_ input: @escaping @Sendable () throws -> Data) {
        pendingBackup = nil
        transferring = true
        let existing = model.entries
        Task {
            defer { transferring = false }
            do {
                pendingBackup = try await Task.detached(priority: .userInitiated) {
                    let backup = try Backup.load(input())
                    return PendingBackup(file: backup, summary: backup.preview(against: existing))
                }.value
            } catch { failure = LogError.invalidBackup.message }
        }
    }
}

private struct PendingBackup: Sendable {
    let file: Backup
    let summary: MergePreview
}

private struct LocalDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data
    let type: UTType
    let name: String

    init(data: Data, type: UTType, name: String) {
        self.data = data
        self.type = type
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw LogError.invalidBackup }
        self.init(data: data, type: configuration.contentType, name: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

