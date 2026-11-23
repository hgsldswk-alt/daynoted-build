import StoreKit
import SwiftUI

@MainActor
struct PaywallView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
    var close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                PageHeader(title: L.t("paywall.title"), subtitle: L.t("paywall.subtitle"), titleID: "paywall.title") {
                    ActionButton(title: L.t("common.close"), id: "paywall.close", action: close)
                }
                Text(L.t("paywall.features")).font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["calendar", "square.grid.2x2", "rectangle.on.rectangle", "tablecells"], id: \.self) { symbol in
                        Label(L.t("paywall.feature." + symbol), systemImage: symbol)
                            .foregroundStyle(Palette.accentText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13).panel(Palette.tint)
                Text(L.t("paywall.free")).font(.subheadline)
                Text(L.t("paywall.terms")).font(.footnote).foregroundStyle(Palette.muted)
                let price = purchases.pro?.displayPrice ?? (Launch.testing ? "$3.99" : nil)
                if let price, !model.entitlement.purchasedPro && !Launch.demoPro {
                    Text(L.format("paywall.priceTerms", price)).font(.footnote).foregroundStyle(Palette.muted)
                }

                if model.entitlement.purchasedPro || Launch.demoPro {
                    Text(L.t("paywall.unlocked")).font(.headline).accessibilityIdentifier("paywall.state")
                } else if model.hasPlus {
                    let end = model.entitlement.trialEnd.formatted(date: .abbreviated, time: .omitted)
                    Text(L.format("paywall.ends", end)).accessibilityIdentifier("paywall.state")
                } else if model.entitlement.hasClaimed || Launch.expired {
                    Text(L.t("paywall.expired")).accessibilityIdentifier("paywall.state")
                } else {
                    ActionButton(title: L.t("paywall.trial"), id: "paywall.trial", style: .primary) {
                        guard let trial = purchases.trial else { return }
                        Task { await purchases.purchase(trial, model: model) }
                    }
                    .disabled(((purchases.trial == nil || purchases.pro == nil) && !Launch.testing) || purchases.working)
                }
                if !model.entitlement.purchasedPro && !Launch.demoPro {
                    ActionButton(title: price.map { L.format("paywall.buyPrice", $0) } ?? L.t("paywall.buy"),
                                 id: "paywall.buy", style: .bordered) {
                        guard let pro = purchases.pro else { return }
                        Task { await purchases.purchase(pro, model: model) }
                    }
                    .disabled((purchases.pro == nil && !Launch.testing) || purchases.working)
                }
                ActionButton(title: L.t("paywall.restore"), id: "paywall.restore") {
                    Task { await purchases.restore(model) }
                }
                .disabled(purchases.working)
                if purchases.loading || purchases.working { ProgressView() }
                if let status = purchases.status { Text(status).font(.footnote).accessibilityIdentifier("paywall.status") }
                if !purchases.loading && (purchases.pro == nil || purchases.trial == nil) && !Launch.testing {
                    ActionButton(title: L.t("common.retry"), id: "paywall.retry", style: .bordered) {
                        Task { await purchases.load() }
                    }
                }
            }
            .padding(20)
        }
        .pageSurface()
        .task { await purchases.load() }
        .toolbar(.hidden, for: .navigationBar)
    }
}

