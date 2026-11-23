import Foundation
import StoreKit
import SwiftUI

@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var pro: Product?
    @Published private(set) var trial: Product?
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var status: String?
    private var listener: Task<Void, Never>?
    private var refreshing = false

    deinit { listener?.cancel() }

    func listen(to model: AppModel) {
        guard !Launch.testing, listener == nil else { return }
        listener = Task { [weak self, weak model] in
            for await change in StoreKit.Transaction.updates {
                guard let self, let model else { return }
                guard case .verified(let transaction) = change, Self.matches(transaction) else { continue }
                do {
                    try await self.apply(transaction, to: model)
                    await transaction.finish()
                } catch { self.status = L.t("store.failed") }
            }
        }
    }

    func load() async {
        guard !Launch.testing, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let products = try await Product.products(for: [Launch.proID, Launch.trialID])
            pro = products.first { $0.id == Launch.proID && $0.type == .nonConsumable }
            trial = products.first { $0.id == Launch.trialID && $0.type == .nonConsumable && $0.price == 0 }
            status = pro == nil || trial == nil ? L.t("store.unavailable") : nil
        } catch { self.status = L.t("store.unavailable") }
    }

    func purchase(_ product: Product, model: AppModel) async {
        guard !Launch.testing, !working else { return }
        working = true
        status = nil
        defer { working = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, Self.matches(transaction) else {
                    status = L.t("store.unverified")
                    return
                }
                try await apply(transaction, to: model)
                await transaction.finish()
            case .pending: status = L.t("store.pending")
            case .userCancelled: break
            @unknown default: status = L.t("store.failed")
            }
        } catch { self.status = L.t("store.failed") }
    }

    func restore(_ model: AppModel) async {
        guard !Launch.testing, !working else { return }
        working = true
        status = nil
        defer { working = false }
        do {
            try await AppStore.sync()
            try await refresh(model, afterExplicitRestore: true)
            status = model.entitlement.hasPro(at: Date()) ? L.t("store.restored") : L.t("store.nothing")
        } catch { self.status = L.t("store.failed") }
    }

    func refreshOnForeground(_ model: AppModel) async {
        guard !Launch.testing, !working, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        try? await refresh(model, afterExplicitRestore: false)
    }

    private func refresh(_ model: AppModel, afterExplicitRestore: Bool) async throws {
        let latestPro = await StoreKit.Transaction.latest(for: Launch.proID)
        let latestTrial = await StoreKit.Transaction.latest(for: Launch.trialID)
        if case .verified(let transaction)? = latestPro, Self.matches(transaction) {
            try await apply(transaction, to: model)
            await transaction.finish()
        } else if latestPro == nil && afterExplicitRestore {
            try await model.recordStoreChange {
                $0.proTransactionID = nil
                $0.proSignedAt = nil
            }
        }
        if case .verified(let transaction)? = latestTrial, Self.matches(transaction) {
            try await apply(transaction, to: model)
            await transaction.finish()
        } else if latestTrial == nil && afterExplicitRestore {
            try await model.recordStoreChange {
                $0.proStartedAt = nil
                $0.trialTransactionID = nil
                $0.trialRevoked = false
                $0.trialSignedAt = nil
            }
        }
    }

    private static func matches(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productType == .nonConsumable &&
            (transaction.productID == Launch.proID || transaction.productID == Launch.trialID)
    }

    private func apply(_ transaction: StoreKit.Transaction, to model: AppModel) async throws {
        try await model.recordStoreChange { entitlement in
            if transaction.productID == Launch.proID {
                if let last = entitlement.proSignedAt, last > transaction.signedDate { return }
                entitlement.proSignedAt = transaction.signedDate
                entitlement.proTransactionID = transaction.revocationDate == nil ? transaction.originalID : nil
            } else {
                if let last = entitlement.trialSignedAt, last > transaction.signedDate { return }
                entitlement.trialSignedAt = transaction.signedDate
                entitlement.proStartedAt = transaction.originalPurchaseDate
                entitlement.trialTransactionID = transaction.originalID
                entitlement.trialRevoked = transaction.revocationDate != nil
            }
        }
    }
}

