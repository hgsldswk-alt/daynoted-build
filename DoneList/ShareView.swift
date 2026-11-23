import SwiftUI
import UIKit

@MainActor
struct ShareView: View {
    @ObservedObject var model: AppModel
    let range: ShareRange
    var close: () -> Void
    var unlock: () -> Void
    @State private var selected: Set<UUID> = []
    @State private var showingEntries = false
    @State private var qr: CGImage?
    @State private var rendered: UIImage?
    @State private var renderedContent: CardContent?
    @State private var activity: ImageActivity?
    @State private var activityFile: URL?
    @State private var preparingShare = false
    @State private var shareTask: Task<Void, Never>?
    @State private var shareRequested = false
    @State private var copied = false
    @State private var failure: String?

    private let storeID = (Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String) ?? ""

    private var address: String { DownloadCode.address(storeID: storeID) }
    private var content: CardContent {
        CardContent(range: range, entries: model.grouped, selected: selected,
                    layout: model.layout.allowed(hasPlus: model.hasPlus),
                    placeholderQR: !address.hasPrefix("https://apps.apple.com/"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: L.t("share.title"), subtitle: L.t("share.preview")) {
                    ActionButton(title: L.t("common.close"), id: "share.close", action: close)
                }
                preview
                ActionButton(title: L.t("share.image"), id: "share.image", style: .primary) {
                    guard let image = rendered?.cgImage, renderedContent == content else { return }
                    prepareShare(image)
                }
                .disabled(rendered == nil || renderedContent != content || preparingShare)
                if shareRequested { Text(L.t("share.requested")).accessibilityIdentifier("share.requested") }
                ErrorLine(text: failure)
                options
            }
            .padding(20)
        }
        .pageSurface()
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let address = address
            qr = await Task.detached(priority: .userInitiated) { DownloadCode.image(for: address) }.value
            if qr == nil { failure = LogError.invalidExport.message }
        }
        .task(id: RenderInput(content: content, ready: qr != nil)) {
            guard let qr else { return }
            let card = content
            rendered = ShareArtwork.render(card, qr: qr)
            renderedContent = card
            if rendered == nil { failure = LogError.invalidExport.message }
        }
        .sheet(item: $activity, onDismiss: removeSharedFile) { item in
            ActivitySheet(url: item.url)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingEntries) { entryPicker }
        .onDisappear { shareTask?.cancel() }
    }

    private var preview: some View {
        Group {
            if let rendered {
                Image(uiImage: rendered).resizable().scaledToFit()
                    .accessibilityLabel(([L.format("share.imageLabel", content.title, content.total)] + content.excerpts)
                        .joined(separator: "\n"))
                    .accessibilityIdentifier("share.preview")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .frame(maxWidth: 330)
        .frame(maxWidth: .infinity)
    }

    private func prepareShare(_ image: CGImage) {
        preparingShare = true
        failure = nil
        shareTask = Task {
            defer { preparingShare = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ShareFile.write(image)
                }.value
                if Launch.testing || Task.isCancelled {
                    await Task.detached { ShareFile.remove(url) }.value
                    if !Task.isCancelled { shareRequested = true }
                } else {
                    activityFile = url
                    activity = ImageActivity(url: url)
                }
            } catch {
                failure = LogError.invalidExport.message
            }
        }
    }

    private func removeSharedFile() {
        guard let url = activityFile else { return }
        activityFile = nil
        Task.detached { ShareFile.remove(url) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t(selected.isEmpty ? "share.private" : "share.selected")).font(.footnote)
                .foregroundStyle(Palette.muted)
            ActionButton(title: L.t("share.choose"), id: "share.choose", style: .bordered) { showingEntries = true }
            Menu {
                ForEach(CardLayout.allCases, id: \.self) { layout in
                    Button {
                        if layout.isPlus && !model.hasPlus { unlock() }
                        else { Task { _ = await model.selectLayout(layout) } }
                    } label: {
                        Label(layout.title, systemImage: layout.isPlus && !model.hasPlus ? "lock" : "rectangle")
                    }
                    .accessibilityIdentifier("layout.\(layout.rawValue)")
                }
            } label: {
                Label(content.layout.title, systemImage: "rectangle.3.group")
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("share.layout")
            ActionButton(title: L.t(copied ? "common.copied" : "share.caption"), id: "share.caption", style: .bordered) {
                UIPasteboard.general.string = L.t(range.kind == .today ? "share.captionToday" : "share.captionWeek")
                copied = true
            }
        }
    }

    private var entryPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                PageHeader(title: L.t("share.choose"), subtitle: L.t("share.limit")) {
                    ActionButton(title: L.t("common.done"), id: "share.entryDone") { showingEntries = false }
                }
                ForEach(range.days.flatMap { model.grouped[$0.key] ?? [] }) { entry in
                    Button {
                        if selected.contains(entry.id) { selected.remove(entry.id) }
                        else if selected.count < 2 { selected.insert(entry.id) }
                    } label: {
                        Label(entry.text, systemImage: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!selected.contains(entry.id) && selected.count >= 2)
                    .accessibilityIdentifier("share.pick.\(entry.id.uuidString)")
                    .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
                }
            }
            .padding(20)
        }
        .pageSurface()
    }

    private struct RenderInput: Equatable {
        let content: CardContent
        let ready: Bool
    }
}

private struct ImageActivity: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

