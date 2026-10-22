import Foundation

extension String {
    var storeForcedRTL: String {
        components(separatedBy: "\n")
            .map { "\u{200F}" + $0 }
            .joined(separator: "\n")
    }
}
