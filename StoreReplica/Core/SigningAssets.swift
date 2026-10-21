import Foundation
import Security

enum SigningAssetError: LocalizedError {
    case wrongP12Extension
    case wrongProvisionExtension
    case emptyFile(String)
    case invalidP12
    case badP12Password
    case invalidProvision
    case expiredProvision
    case certificateMismatch

    var errorDescription: String? {
        switch self {
        case .wrongP12Extension:
            return "اختر ملف شهادة بامتداد .p12 فقط."
        case .wrongProvisionExtension:
            return "اختر ملف Provision بامتداد .mobileprovision فقط."
        case .emptyFile(let name):
            return "الملف \(name) فارغ أو غير قابل للقراءة."
        case .invalidP12:
            return "ملف P12 غير صالح أو لا يحتوي هوية توقيع."
        case .badP12Password:
            return "كلمة مرور P12 غير صحيحة."
        case .invalidProvision:
            return "ملف MobileProvision غير صالح."
        case .expiredProvision:
            return "ملف MobileProvision منتهي الصلاحية."
        case .certificateMismatch:
            return "شهادة P12 لا تطابق شهادة MobileProvision."
        }
    }
}

enum SigningAssetProvider {
    struct Credentials {
        let p12: URL
        let mobileProvision: URL
        let password: String
    }

    private static let keychainService = "com.ikiraplus.turathreplica.signing"
    private static let keychainAccount = "p12-password"

    private static var directory: URL? {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let folder = root.appendingPathComponent("SigningAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var storedP12: URL? {
        directory?.appendingPathComponent("certificate.p12")
    }

    private static var storedProvision: URL? {
        directory?.appendingPathComponent("certificate.mobileprovision")
    }

    static var hasP12File: Bool {
        guard let storedP12 else { return false }
        return FileManager.default.fileExists(atPath: storedP12.path)
    }

    static var hasProvisionFile: Bool {
        guard let storedProvision else { return false }
        return FileManager.default.fileExists(atPath: storedProvision.path)
    }

    static var hasCredentials: Bool {
        guard let value = try? credentials() else { return false }
        return (try? validate(credentials: value)) != nil
    }

    static func credentials() throws -> Credentials {
        if let p12 = storedP12,
           let mobile = storedProvision,
           FileManager.default.fileExists(atPath: p12.path),
           FileManager.default.fileExists(atPath: mobile.path),
           let password = loadPassword() {
            return Credentials(p12: p12, mobileProvision: mobile, password: password)
        }

        let bundle = Bundle.main
        if let p12 = bundle.url(forResource: "cert", withExtension: "p12"),
           let mobile = bundle.url(forResource: "cert", withExtension: "mobileprovision"),
           let passwordURL = bundle.url(forResource: "cert", withExtension: "txt"),
           let password = try? String(contentsOf: passwordURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) {
            return Credentials(p12: p12, mobileProvision: mobile, password: password)
        }

        throw StoreInstallError.missingSigningAssets
    }

    static func importP12(from source: URL) throws {
        guard source.pathExtension.lowercased() == "p12" else {
            throw SigningAssetError.wrongP12Extension
        }
        guard let target = storedP12 else { throw StoreInstallError.missingSigningAssets }
        try copySecurityScoped(source, to: target, displayName: source.lastPathComponent)
    }

    static func importProvision(from source: URL) throws {
        guard source.pathExtension.lowercased() == "mobileprovision" else {
            throw SigningAssetError.wrongProvisionExtension
        }
        guard let target = storedProvision else { throw StoreInstallError.missingSigningAssets }
        try copySecurityScoped(source, to: target, displayName: source.lastPathComponent)
        _ = try provisionDictionary(at: target)
    }

    static func validateAndSavePassword(_ password: String) throws {
        guard let p12 = storedP12,
              let mobile = storedProvision,
              FileManager.default.fileExists(atPath: p12.path),
              FileManager.default.fileExists(atPath: mobile.path) else {
            throw StoreInstallError.missingSigningAssets
        }

        let value = Credentials(p12: p12, mobileProvision: mobile, password: password)
        try validate(credentials: value)
        try savePassword(password)
    }

    static func validate(credentials: Credentials) throws {
        let identityCertificate = try identityCertificateData(
            p12URL: credentials.p12,
            password: credentials.password
        )
        let provision = try provisionDictionary(at: credentials.mobileProvision)

        if let expiration = provision["ExpirationDate"] as? Date, expiration <= Date() {
            throw SigningAssetError.expiredProvision
        }

        guard let developerCertificates = provision["DeveloperCertificates"] as? [Data],
              !developerCertificates.isEmpty else {
            throw SigningAssetError.invalidProvision
        }

        guard developerCertificates.contains(identityCertificate) else {
            throw SigningAssetError.certificateMismatch
        }
    }

    static func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func identityCertificateData(p12URL: URL, password: String) throws -> Data {
        let data = try Data(contentsOf: p12URL)
        guard !data.isEmpty else { throw SigningAssetError.emptyFile(p12URL.lastPathComponent) }

        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &imported)
        if status == errSecAuthFailed {
            throw SigningAssetError.badP12Password
        }
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let first = items.first,
              let identity = first[kSecImportItemIdentity as String] as? SecIdentity else {
            throw SigningAssetError.invalidP12
        }

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw SigningAssetError.invalidP12
        }
        return SecCertificateCopyData(certificate) as Data
    }

    private static func provisionDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw SigningAssetError.emptyFile(url.lastPathComponent) }

        let xmlStart = Data("<?xml".utf8)
        let xmlEnd = Data("</plist>".utf8)
        guard let startRange = data.range(of: xmlStart),
              let endRange = data.range(of: xmlEnd, in: startRange.lowerBound..<data.endIndex) else {
            throw SigningAssetError.invalidProvision
        }

        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
              plist["UUID"] != nil else {
            throw SigningAssetError.invalidProvision
        }
        return plist
    }

    private static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func copySecurityScoped(_ source: URL, to target: URL, displayName: String) throws {
        let granted = source.startAccessingSecurityScopedResource()
        defer {
            if granted { source.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        if let size = attributes[.size] as? NSNumber, size.int64Value <= 0 {
            throw SigningAssetError.emptyFile(displayName)
        }

        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }

        try fm.copyItem(at: source, to: temporary)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: temporary, to: target)
    }
}
