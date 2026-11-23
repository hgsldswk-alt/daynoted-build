import Foundation

enum Launch {
    static let freePeriod = false
    static let proID = "com.hgsldswk.daynoted.pro"
    static let trialID = "com.hgsldswk.daynoted.trial"
    static let arguments = ProcessInfo.processInfo.arguments
    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    static var forcePaywall: Bool { testing && arguments.contains("-paywall") }
    static var expired: Bool { testing && arguments.contains("-expired") }
    static var demoPro: Bool { testing && arguments.contains("-pro") }
    static var seed: Bool { testing && arguments.contains("-seed") }
    static var reset: Bool { testing && arguments.contains("-reset") }
}

