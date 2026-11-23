import SwiftUI

extension View {
    func panel(_ color: Color = Palette.surface, radius: CGFloat = 19) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.line).allowsHitTesting(false))
    }

    func pageSurface() -> some View {
        foregroundStyle(Palette.ink)
            .background(Palette.paper.ignoresSafeArea())
            .tint(Palette.accentText)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleID: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let titleID {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier(titleID)
                } else {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct ActionButton: View {
    enum Style { case text, bordered, primary }

    let title: String
    let id: String
    var style: Style = .text
    var icon: String? = nil
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Group {
                if let icon { Label(title, systemImage: icon) } else { Text(title) }
            }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: style == .text ? nil : .infinity)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: style == .primary ? 50 : 44)
            .foregroundStyle(role == .destructive ? Color.red : style == .primary ? .white : Palette.accentText)
            .background(style == .primary ? Palette.accentText : style == .bordered ? Palette.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                if style == .bordered {
                    RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.line).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct ErrorLine: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("error.line")
        }
    }
}

struct EntryRows: View {
    let entries: [DoneEntry]
    var compact = false
    var open: (DoneEntry) -> Void

    var body: some View {
        ForEach(entries) { entry in
            Button {
                open(entry)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.text)
                        .font(compact ? .subheadline : .body.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !compact {
                        Text(entry.createdAt.formatted(timeStyle(entry)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.text)
            .accessibilityValue(compact ? "" : entry.createdAt.formatted(timeStyle(entry)))
            .accessibilityIdentifier("entry.\(entry.id.uuidString)")
            if entry.id != entries.last?.id { Divider().overlay(Palette.line).accessibilityHidden(true) }
        }
    }

    private func timeStyle(_ entry: DoneEntry) -> Date.FormatStyle {
        var style = Date.FormatStyle().hour().minute()
        style.timeZone = TimeZone(identifier: entry.captureTimeZone) ?? .autoupdatingCurrent
        return style
    }
}

