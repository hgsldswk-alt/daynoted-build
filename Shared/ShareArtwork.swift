import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ShareRange: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case today, week, milestone }
    let id = UUID()
    let kind: Kind
    let days: [Day]

    var title: String {
        switch kind {
        case .today: return L.t("card.today")
        case .week: return L.t("card.week")
        case .milestone: return L.t("card.milestone")
        }
    }
}

struct CardContent: Equatable, Sendable {
    let title: String
    let counts: [Int]
    let excerpts: [String]
    let layout: CardLayout
    let placeholderQR: Bool

    var total: Int { counts.reduce(0, +) }

    init(range: ShareRange, entries: [String: [DoneEntry]], selected: Set<UUID> = [],
         layout: CardLayout, placeholderQR: Bool) {
        let days = range.days.reversed()
        title = range.title
        counts = days.map { entries[$0.key]?.count ?? 0 }
        excerpts = days.flatMap { entries[$0.key] ?? [] }.filter { selected.contains($0.id) }.prefix(2).map(\.text)
        self.layout = layout
        self.placeholderQR = placeholderQR
    }
}

@MainActor
struct ShareArtwork: View {
    let content: CardContent
    let qr: CGImage

    static func render(_ content: CardContent, qr: CGImage) -> UIImage? {
        let renderer = ImageRenderer(content: ShareArtwork(content: content, qr: qr))
        renderer.scale = 3
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 360, height: 450)
        return renderer.uiImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("app.name")).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.accentText)
            Text(content.title).font(.system(size: 33, weight: .bold)).minimumScaleFactor(0.65)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(content.total.formatted()).font(.system(size: 53, weight: .bold, design: .monospaced))
                Text(L.t("card.count")).font(.system(size: 16, weight: .semibold)).minimumScaleFactor(0.7)
            }
            .foregroundStyle(Palette.accentText)
            if content.counts.count > 1 { distribution }
            if !content.excerpts.isEmpty {
                GeometryReader { space in
                    ViewThatFits(in: .vertical) {
                        excerpts(size: 13)
                        excerpts(size: 11)
                        excerpts(size: 9)
                        excerpts(size: 7)
                        excerpts(size: 5)
                        excerpts(size: 2)
                        excerpts(size: 1)
                    }
                    .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
                }
                .padding(7).background(Palette.tint, in: RoundedRectangle(cornerRadius: 9))
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("share.tags")).font(.system(size: 14, weight: .bold)).minimumScaleFactor(0.7)
                    Text(L.t(content.placeholderQR ? "card.qrPreview" : "card.qrDownload"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 4)
                Image(decorative: qr, scale: 1).resizable().interpolation(.none).frame(width: 64, height: 64)
            }
        }
        .padding(24)
        .frame(width: 360, height: 450, alignment: .topLeading)
        .foregroundStyle(Palette.ink)
        .background(content.layout == .bars ? Palette.tint : content.layout == .plain ? Palette.surface : Palette.paper)
        .environment(\.dynamicTypeSize, .medium)
    }

    private func excerpts(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(content.excerpts.enumerated()), id: \.offset) { _, text in
                Text(text).font(.system(size: size))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var distribution: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(content.counts.enumerated()), id: \.offset) { index, count in
                VStack(spacing: 3) {
                    if content.layout == .bars {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.accent)
                            .frame(height: max(3, 32 * CGFloat(count) / CGFloat(max(content.counts.max() ?? 0, 1))))
                    }
                    Text(count.formatted()).font(.system(size: 17, weight: .bold, design: .monospaced))
                    Text(L.format("card.day", index + 1)).font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Palette.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(content.layout == .rows ? Palette.tint : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
}

enum ShareFile {
    static func write(_ image: CGImage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("Daynoted.png")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw LogError.invalidExport
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LogError.invalidExport }
        do {
            try LocalFiles.prepare(directory)
            try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        } catch {
            remove(url)
            throw error
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

