import SwiftUI

@MainActor
struct ReviewView: View {
    enum Period: String, CaseIterable {
        case week, month, custom
        var title: String { L.t("period." + rawValue) }
    }

    @ObservedObject var model: AppModel
    @Binding var period: Period
    var history: () -> Void
    var paywall: () -> Void
    var share: (ShareRange) -> Void
    @State private var showRange = false
    @Binding var start: Day?
    @Binding var end: Day?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                PageHeader(title: L.t("review.title"), subtitle: subtitle) {
                    ActionButton(title: L.t("history.title"), id: "review.history", action: history)
                }
                summary
                if model.milestone {
                    HStack {
                        Text(L.t("milestone.title")).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        ActionButton(title: L.t("share.title"), id: "review.milestoneShare") {
                            share(ShareRange(kind: .milestone, days: model.week))
                        }
                    }
                    .padding(.horizontal, 10).panel(Palette.tint)
                }
                if days.isEmpty { Text(L.t("review.empty")).foregroundStyle(Palette.muted) }
                ForEach(days, id: \.key) { day in
                    DaySection(day: day, entries: model.grouped[day.key] ?? [], edit: model.edit)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .onChange(of: model.hasPlus) { _, plus in if !plus { period = .week } }
        .sheet(isPresented: $showRange) {
            RangeView(today: model.today, start: start ?? model.today.adding(-6), end: end ?? model.today) { first, last in
                guard model.hasPlus else { showRange = false; return }
                start = first
                end = last
                period = .custom
                showRange = false
            } cancel: {
                showRange = false
            }
        }
    }

    private var activePeriod: Period { model.hasPlus ? period : .week }

    private var days: [Day] {
        switch activePeriod {
        case .week: return model.week
        case .month: return Day.range(from: model.today.monthStart, through: model.today)
        case .custom:
            let first = (start ?? model.today.adding(-6)).key
            let last = min(end ?? model.today, model.today).key
            return model.grouped.keys.filter { $0 >= first && $0 <= last }.sorted(by: >).compactMap(Day.init(key:))
        }
    }

    private var subtitle: String {
        let first: Day
        let last: Day
        switch activePeriod {
        case .week: first = model.today.adding(-6); last = model.today
        case .month: first = model.today.monthStart; last = model.today
        case .custom:
            first = start ?? model.today.adding(-6)
            last = min(end ?? model.today, model.today)
        }
        return L.format("period.span", first.formatted(.dateTime.month(.abbreviated).day()),
                        last.formatted(.dateTime.month(.abbreviated).day().year()))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.format("today.count", days.reduce(0) { $0 + (model.grouped[$1.key]?.count ?? 0) }))
                    .font(.title2.bold().monospacedDigit()).foregroundStyle(Palette.accentText)
                Spacer(minLength: 2)
                Menu {
                    ForEach(Period.allCases, id: \.self) { option in
                        Button(option.title) {
                            if option != .week && !model.hasPlus { paywall() }
                            else if option == .custom { showRange = true }
                            else { period = option }
                        }
                        .accessibilityIdentifier("period.\(option.rawValue)")
                    }
                } label: {
                    Label(activePeriod.title, systemImage: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("review.period")
            }
            if activePeriod == .week {
                HStack(spacing: 4) {
                    ForEach(Array(days.reversed()), id: \.key) { day in
                        let count = model.grouped[day.key]?.count ?? 0
                        VStack(spacing: 2) {
                            Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2)
                            Text(count.formatted()).font(.caption.monospacedDigit().bold())
                        }
                        .padding(.vertical, 5).frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .foregroundStyle(count == 0 ? Palette.muted : Palette.accentText)
                        .background(count == 0 ? Palette.paper : Palette.tint, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L.format("review.dayCount", day.formatted(.dateTime.weekday(.wide)), count))
                        .accessibilityIdentifier("review.count.\(day.key)")
                    }
                }
                ActionButton(title: L.t("share.title"), id: "review.share", style: .bordered) {
                    share(ShareRange(kind: .week, days: model.week))
                }
                .disabled(!days.contains { !(model.grouped[$0.key] ?? []).isEmpty })
            }
        }
        .padding(12).panel()
    }
}

private struct DaySection: View {
    let day: Day
    let entries: [DoneEntry]
    var edit: (DoneEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.accentText)
                .accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text(L.t("review.empty")).font(.caption).foregroundStyle(Palette.muted)
                    .frame(minHeight: 26, alignment: .leading)
            } else {
                EntryRows(entries: entries, compact: true, open: edit)
            }
            Divider().overlay(Palette.line).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.day.\(day.key)")
    }
}

@MainActor
struct HistoryView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var query = ""

    private struct Group: Identifiable {
        let day: Day
        let entries: [DoneEntry]
        var id: String { day.key }
    }

    private var groups: [Group] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = needle.isEmpty ? model.entries : model.entries.filter { $0.text.localizedStandardContains(needle) }
        let grouped = Dictionary(grouping: entries, by: \.dayKey)
        return grouped.keys.sorted(by: >).compactMap { key in
            guard let day = Day(key: key), let entries = grouped[key] else { return nil }
            return Group(day: day, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(title: L.t("history.title")) {
                ActionButton(title: L.t("common.close"), id: "history.close", action: close)
            }
            HStack {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField(L.t("history.search"), text: $query)
                    .submitLabel(.search)
                    .accessibilityIdentifier("history.search")
            }
            .padding(.horizontal, 12).frame(minHeight: 44).panel()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    let matches = groups
                    if matches.isEmpty { Text(L.t("history.empty")).foregroundStyle(Palette.muted) }
                    ForEach(matches) { group in
                        DaySection(day: group.day, entries: group.entries, edit: model.edit)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 20).padding(.top, 10)
        .pageSurface()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct RangeView: View {
    let today: Day
    @State private var start: Day
    @State private var end: Day
    var apply: (Day, Day) -> Void
    var cancel: () -> Void

    init(today: Day, start: Day, end: Day, apply: @escaping (Day, Day) -> Void, cancel: @escaping () -> Void) {
        self.today = today
        _start = State(initialValue: min(start, today))
        _end = State(initialValue: min(end, today))
        self.apply = apply
        self.cancel = cancel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: L.t("period.custom")) {
                    ActionButton(title: L.t("common.cancel"), id: "range.cancel", action: cancel)
                }
                DatePicker(L.t("range.start"), selection: Binding(
                    get: { start.date() },
                    set: { start = Day($0); end = max(start, end) }
                ), in: ...today.date(), displayedComponents: .date)
                .accessibilityIdentifier("range.start")
                DatePicker(L.t("range.end"), selection: Binding(
                    get: { end.date() }, set: { end = Day($0) }
                ), in: start.date()...today.date(), displayedComponents: .date)
                .accessibilityIdentifier("range.end")
                ActionButton(title: L.t("common.apply"), id: "range.apply", style: .primary) { apply(start, end) }
            }
            .padding(20)
        }
        .pageSurface()
        .presentationDetents([.medium, .large])
    }
}

