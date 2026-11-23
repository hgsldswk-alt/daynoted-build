import SwiftUI
import WidgetKit

private struct WidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct DaynotedProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: Date(), snapshot: WidgetSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            var snapshot = WidgetSnapshot.read()
            if context.isPreview { snapshot = WidgetSnapshot(counts: [Day(now).key: 4], plusForever: true) }
            completion(WidgetEntry(date: now, snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let snapshot = WidgetSnapshot.read()
            let calendar = Day.calendar()
            let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                            matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
            var dates = [now, midnight]
            if let start = snapshot.plusFrom, start > now, start != midnight { dates.append(start) }
            if let end = snapshot.plusUntil, end > now, end != midnight { dates.append(end) }
            let entries = dates.sorted().map { WidgetEntry(date: $0, snapshot: snapshot) }
            completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
        }
    }
}

private struct DaynotedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WidgetEntry

    private let ink = Color(red: 43/255, green: 110/255, blue: 53/255)
    private let tint = Color(red: 226/255, green: 249/255, blue: 229/255)
    private let todayURL = URL(string: "daynoted://today")!
    private let reviewURL = URL(string: "daynoted://review")!
    private let logURL = URL(string: "daynoted://log")!

    private var today: Day { Day(entry.date) }
    private var week: [Day] { Array(Day.range(from: today.adding(-6), through: today).reversed()) }
    private var showWeek: Bool { family == .systemMedium && entry.snapshot.hasPlus(at: entry.date) }

    var body: some View {
        HStack(spacing: 5) {
            mainContent
                .frame(maxWidth: .infinity, alignment: .leading)
            if family == .systemSmall {
                addIcon
            } else {
                Link(destination: logURL) { addIcon }
                    .accessibilityIdentifier("widget.log")
            }
        }
        .foregroundStyle(ink)
        .containerBackground(tint, for: .widget)
        .widgetURL(family == .systemSmall ? logURL : showWeek ? reviewURL : todayURL)
    }

    @ViewBuilder private var mainContent: some View {
        if showWeek {
            Link(destination: reviewURL) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("period.week")).font(.caption.bold())
                    HStack(spacing: 4) {
                        ForEach(week, id: \.key) { day in
                            VStack(spacing: 2) {
                                Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2)
                                Text(entry.snapshot.count(day).formatted()).font(.caption.bold().monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .accessibilityIdentifier("widget.review")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("today.title")).font(.caption.bold())
                Text(L.format("today.count", entry.snapshot.count(today))).font(.title2.bold().monospacedDigit())
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(today.formatted(.dateTime.month(.abbreviated).day())).font(.caption2)
            }
        }
    }

    private var addIcon: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 30))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(L.t("entry.prompt"))
    }
}

@main
struct DoneListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Daynoted", provider: DaynotedProvider()) { entry in
            DaynotedWidgetView(entry: entry)
        }
        .configurationDisplayName(L.t("app.name"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

