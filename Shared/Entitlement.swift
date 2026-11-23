import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 30 * 24 * 60 * 60

    var firstOpen: Date
    var proStartedAt: Date?
    var trialTransactionID: UInt64?
    var proTransactionID: UInt64?
    var proSignedAt: Date?
    var trialSignedAt: Date?
    var trialRevoked = false

    var trialStart: Date { proStartedAt ?? firstOpen }
    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }
    var hasClaimed: Bool { trialTransactionID != nil }
    var purchasedPro: Bool { proTransactionID != nil }

    func hasPro(at now: Date, free: Bool = Launch.freePeriod) -> Bool {
        free || purchasedPro || (hasClaimed && !trialRevoked && now >= trialStart && now < trialEnd)
    }
}

