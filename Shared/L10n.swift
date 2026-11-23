import Foundation

final class LocalizationAnchor: NSObject {}

enum L {
    static var bundle: Bundle { Bundle(for: LocalizationAnchor.self) }

    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }
}

