import Foundation

extension String {
    var storeForcedRTL: String {
        let localized = StoreLanguage.localized(self)
        if StoreLanguage.isEnglish { return localized }
        return localized.components(separatedBy: "\n")
            .map { "\u{200F}" + $0 }
            .joined(separator: "\n")
    }
}

enum StoreLanguage {
    static var isEnglish: Bool {
        UserDefaults.standard.string(forKey: "store.language") == "en"
    }

    /// For dynamic SwiftUI labels that don't use a LocalizedStringKey.
    static func localized(_ key: String) -> String {
        guard isEnglish,
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
    }
}
