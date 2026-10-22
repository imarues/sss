import Foundation

// Small helpers used by the sideload pipeline when manipulating plist identifiers
// and Content-Disposition values without allocating intermediary strings everywhere.
func + (lhs: String, rhs: Substring) -> String {
    lhs + String(rhs)
}

func + (lhs: Substring, rhs: String) -> String {
    String(lhs) + rhs
}

extension Substring {
    func trimmingCharacters(in set: CharacterSet) -> String {
        String(self).trimmingCharacters(in: set)
    }
}
