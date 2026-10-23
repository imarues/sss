import Foundation

extension String {
    var storeForcedRTL: String {
        if UserDefaults.standard.string(forKey: "store.language") == "en" { return self }
        return components(separatedBy: "\n")
            .map { "\u{200F}" + $0 }
            .joined(separator: "\n")
    }
}
