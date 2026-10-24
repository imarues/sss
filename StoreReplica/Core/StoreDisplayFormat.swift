import Foundation

/// Latin 0-9 digits and English B / KB / MB / GB for every interface language.
enum StoreDisplayFormat {
    static let latinLocale = Locale(identifier: "en_US_POSIX")
    static let arabicLatinLocale = Locale(identifier: "ar_IQ@numbers=latn")

    static func digits(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0660...0x0669:
                return Unicode.Scalar(scalar.value - 0x0660 + 0x30)!
            case 0x06F0...0x06F9:
                return Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!
            default:
                return scalar
            }
        }))
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(latinLocale))
    }

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        if value == 0 { return "0 B" }
        let count = Double(value)
        let amount: Double
        let suffix: String
        if count >= 1_000_000_000 {
            amount = count / 1_000_000_000
            suffix = "GB"
        } else if count >= 1_000_000 {
            amount = count / 1_000_000
            suffix = "MB"
        } else if count >= 1_000 {
            amount = count / 1_000
            suffix = "KB"
        } else {
            return "\(value) B"
        }
        return String(format: "%.1f %@", locale: latinLocale, amount, suffix)
    }
}
