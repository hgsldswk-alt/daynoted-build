import Combine
import StoreKit
import SwiftUI
import UIKit

@main
struct DoneListApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView().preferredColorScheme(.light)
        }
    }
}

@MainActor
private struct HomeView: View {
    private enum Tab { case today, review }
    private enum Screen: Hashable {
        case settings, history, share(ShareRange), plus
    }

    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases()
    @State private var tab = Tab.today
    @State private var period = ReviewView.Period.week
    @State private var customStart: Day?
    @State private var customEnd: Day?
    @State private var focused = false
    @State private var path: [Screen] = []
    @State private var pendingLink: URL?
    @State private var appliedDebugRoute = false

    private let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if tab == .today {
                    TodayView(model: model, focus: $focused, settings: { path.append(.settings) }, share: {
                        path.append(.share(ShareRange(kind: .today, days: [model.today])))
                    }, milestone: {
                        period = .week
                        tab = .review
                        Task { await model.dismissMilestone() }
                    })
                } else {
                    ReviewView(model: model, period: $period, history: { path.append(.history) },
                               paywall: { path.append(.plus) }, share: { path.append(.share($0)) },
                               start: $customStart, end: $customEnd)
                }
                if !focused { tabs.padding(.horizontal, 20).padding(.bottom, 4) }
            }
            .pageSurface()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .settings:
                    SettingsView(model: model, close: back, paywall: { path.append(.plus) })
                case .history:
                    HistoryView(model: model, close: back)
                case .share(let range):
                    ShareView(model: model, range: range, close: back, unlock: { path.append(.plus) })
                case .plus:
                    PaywallView(model: model, purchases: purchases, close: back)
                }
            }
        }
        .pageSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.deleted != nil && !focused {
                HStack {
                    Text(L.t("edit.deleted")).font(.footnote)
                    Spacer(minLength: 2)
                    ActionButton(title: L.t("edit.undo"), id: "entry.undo") { Task { await model.undo() } }
                    ActionButton(title: L.t("common.dismiss"), id: "entry.dismissUndo") { model.dismissUndo() }
                }
                .padding(.horizontal, 8)
                .panel(Palette.tint)
                .padding(.horizontal, 20)
            }
        }
        .sheet(isPresented: Binding(get: { model.editorShown }, set: { shown in
            if !shown { model.closeEditorForNavigation() }
        })) {
            EditView(model: model)
        }
        .task { await model.start() }
        .task(id: model.ready) {
            guard model.ready else { return }
            if let pendingLink { route(pendingLink) }
            if Launch.testing && !appliedDebugRoute {
                appliedDebugRoute = true
                if Launch.forcePaywall { path.append(.plus) }
                if Launch.arguments.contains("-quick-log"), let url = URL(string: "daynoted://log") { route(url) }
            }
            if phase == .active { await model.noteUseDay() }
            purchases.listen(to: model)
            await purchases.refreshOnForeground(model)
        }
        .task(id: phase) {
            guard phase == .active else { return }
            await model.tick()
            await model.noteUseDay()
            Task {
                if model.ready { await purchases.refreshOnForeground(model) }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { break }
                await model.tick()
                await model.noteUseDay()
            }
        }
        .task(id: canPromptForReview) {
            guard canPromptForReview else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard canPromptForReview else { return }
            if await model.claimReview(version: version) {
                if modalIdle { requestReview() }
                else { await model.unclaimReview(version: version) }
            }
        }
        .onOpenURL(perform: route)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await model.tick() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await model.tick() }
        }
    }

    private var modalIdle: Bool {
        phase == .active && path.isEmpty && !model.editorShown && model.draft == nil &&
            !focused && !model.busy && model.error == nil && model.deleted == nil && !purchases.working
    }

    private var canPromptForReview: Bool {
        !Launch.testing && model.ready && modalIdle && model.progress.canRequest(version: version)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.today, title: L.t("today.title"), id: "tab.today")
            tabButton(.review, title: L.t("review.title"), id: "tab.review")
        }
        .padding(4).panel(radius: 16)
    }

    private func tabButton(_ value: Tab, title: String, id: String) -> some View {
        Button {
            focused = false
            tab = value
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(tab == value ? Palette.accentText : Palette.muted)
                .background(tab == value ? Palette.tint : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private func back() {
        if !path.isEmpty { path.removeLast() }
    }

    private func route(_ url: URL) {
        guard url.scheme == "daynoted", ["log", "review", "today"].contains(url.host ?? "") else { return }
        guard model.ready else { pendingLink = url; return }
        pendingLink = nil
        path.removeAll()
        if model.editing != nil { model.closeEditorForNavigation() }
        focused = false
        switch url.host {
        case "log":
            tab = .today
            model.begin()
            focused = true
        case "review":
            period = .week
            tab = .review
        default: tab = .today
        }
    }
}

