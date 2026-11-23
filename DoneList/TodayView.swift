import SwiftUI

@MainActor
struct TodayView: View {
    @ObservedObject var model: AppModel
    @Binding var focus: Bool
    var settings: () -> Void
    var share: () -> Void
    var milestone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: L.t("today.title"), subtitle: model.today.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                    ActionButton(title: L.t(model.draft == nil ? "settings.title" : "common.cancel"),
                                 id: model.draft == nil ? "today.settings" : "entry.cancel") {
                        if model.draft == nil { settings() }
                        else {
                            focus = false
                            model.cancel()
                        }
                    }
                }
                if model.draft == nil {
                    Button {
                        model.begin()
                        focus = true
                    } label: {
                        Label {
                            Text(L.t("entry.prompt")).font(.body.weight(.semibold))
                        } icon: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.accent).allowsHitTesting(false))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.compose")
                    .disabled(!model.ready)
                } else {
                    Composer(model: model, focused: $focus)
                }

                if model.unavailable {
                    ErrorLine(text: model.error)
                    ActionButton(title: L.t("common.retry"), id: "today.retry", style: .bordered) {
                        Task { await model.start() }
                    }
                } else if model.draft == nil && model.ready {
                    records
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 16) {
            ErrorLine(text: model.error)
            if model.todayEntries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: 42, weight: .light))
                        .foregroundStyle(Palette.accentText).accessibilityHidden(true)
                    Text(L.t("today.empty")).font(.headline)
                    Text(L.t("today.emptyHint")).font(.subheadline).foregroundStyle(Palette.muted)
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today.empty")
            } else {
                HStack(alignment: .center) {
                    Text(L.format("today.count", model.todayEntries.count))
                        .font(.title2.bold().monospacedDigit()).foregroundStyle(Palette.accentText)
                    Spacer(minLength: 3)
                    ActionButton(title: L.t("share.titleShort"), id: "today.share", action: share)
                }
                VStack(spacing: 0) {
                    EntryRows(entries: model.todayEntries, open: model.edit)
                }
                .padding(.horizontal, 14)
                .panel()
            }
            if model.milestone && !model.progress.dismissedMilestone {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.t("milestone.title")).font(.headline)
                    HStack {
                        ActionButton(title: L.t("review.title"), id: "milestone.open", action: milestone)
                        Spacer()
                        ActionButton(title: L.t("common.dismiss"), id: "milestone.dismiss") {
                            Task { await model.dismissMilestone() }
                        }
                    }
                }
                .padding(13).panel(Palette.tint)
            }
        }
    }
}

@MainActor
struct EditView: View {
    @ObservedObject var model: AppModel
    @State private var focused = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: L.t("edit.title")) {
                    ActionButton(title: L.t("common.cancel"), id: "edit.cancel") { model.cancel(editing: true) }
                }
                Composer(model: model, editing: true, focused: $focused)
                ActionButton(title: L.t("edit.delete"), id: "edit.delete", role: .destructive) {
                    Task { await model.deleteEditing() }
                }
                .disabled(model.busy)
            }
            .padding(20)
        }
        .pageSurface()
        .interactiveDismissDisabled(model.busy)
    }
}

