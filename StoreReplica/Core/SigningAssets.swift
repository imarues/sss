import Foundation
import Security

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
        (try? credentials()) != nil
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
        guard let target = storedP12 else { throw StoreInstallError.missingSigningAssets }
        try copySecurityScoped(source, to: target)
    }

    static func importProvision(from source: URL) throws {
        guard let target = storedProvision else { throw StoreInstallError.missingSigningAssets }
        try copySecurityScoped(source, to: target)
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

    private static func copySecurityScoped(_ source: URL, to target: URL) throws {
        let granted = source.startAccessingSecurityScopedResource()
        defer {
            if granted { source.stopAccessingSecurityScopedResource() }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
    }
}
