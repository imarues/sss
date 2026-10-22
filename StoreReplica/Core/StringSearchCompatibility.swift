import Foundation

extension String {
    func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        return range(
            of: prefix,
            options: [.caseInsensitive, .diacriticInsensitive, .anchored],
            range: nil,
            locale: Locale.current
        ) != nil
    }
}
