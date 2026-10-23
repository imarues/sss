import Foundation
import Security
import ZsignSwift
import CryptoKit

enum SigningAssetError: LocalizedError {
    case wrongP12Extension
    case wrongProvisionExtension
    case emptyFile(String)
    case invalidP12
    case unsupportedP12Format(Int)
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
            return "ملف P12 لا يحتوي شهادة ومفتاحاً خاصاً متطابقين."
        case .unsupportedP12Format(let status):
            return "تعذر قراءة صيغة P12 (Security.framework: \\(status)). تأكد من كلمة المرور والملف الأصلي."
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

    struct CertificateDetails {
        let name: String
        let profileUUID: String
        let certificateSHA256: String
        let expiration: Date
        let provisionedUDIDs: [String]
    }

    struct InspectedCertificate {
        let p12Data: Data
        let provisionData: Data
        let details: CertificateDetails
    }

    /// Inspect imported documents without changing the active signing identity.
    /// The same validation is used by the certificate manager and signing setup.
    static func inspectCertificate(p12URL: URL, profileURL: URL, password: String) throws -> InspectedCertificate {
        guard p12URL.pathExtension.lowercased() == "p12" else {
            throw SigningAssetError.wrongP12Extension
        }
        guard profileURL.pathExtension.lowercased() == "mobileprovision" else {
            throw SigningAssetError.wrongProvisionExtension
        }
        let p12Data = try readSecurityScopedData(from: p12URL)
        let provisionData = try readSecurityScopedData(from: profileURL)
        guard !p12Data.isEmpty else { throw SigningAssetError.emptyFile(p12URL.lastPathComponent) }
        guard !provisionData.isEmpty else { throw SigningAssetError.emptyFile(profileURL.lastPathComponent) }
        let details = try details(p12Data: p12Data, provisionData: provisionData, password: password)
        return InspectedCertificate(p12Data: p12Data, provisionData: provisionData, details: details)
    }

    static func details(credentials: Credentials) throws -> CertificateDetails {
        let p12Data = try Data(contentsOf: credentials.p12)
        let provisionData = try Data(contentsOf: credentials.mobileProvision)
        return try details(p12Data: p12Data, provisionData: provisionData, password: credentials.password)
    }

    static func currentCertificateDetails() throws -> CertificateDetails {
        try details(credentials: credentials())
    }

    static func details(p12Data: Data, provisionData: Data, password: String) throws -> CertificateDetails {
        let profile = try provisionDictionary(data: provisionData)
        let certData = try identityCertificateData(
            p12Data: p12Data, password: password,
            expectedCertificates: profile["DeveloperCertificates"] as? [Data]
        )
        try validate(identityCertificate: certData, provision: profile)
        guard let expires = profile["ExpirationDate"] as? Date,
              let identifier = profile["UUID"] as? String else {
            throw SigningAssetError.invalidProvision
        }
        let cert = SecCertificateCreateWithData(nil, certData as CFData)
        let subject = cert.flatMap { SecCertificateCopySubjectSummary($0) }.map { String(describing: $0) }
        let name = (subject?.isEmpty == false ? subject : nil)
            ?? (profile["Name"] as? String)
            ?? "Certificate"
        return CertificateDetails(
            name: name,
            profileUUID: identifier,
            certificateSHA256: SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined(),
            expiration: expires,
            provisionedUDIDs: profile["ProvisionedDevices"] as? [String] ?? []
        )
    }

    static func clearActiveCertificate() {
        if let storedP12 { try? FileManager.default.removeItem(at: storedP12) }
        if let storedProvision { try? FileManager.default.removeItem(at: storedProvision) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Switch the certificate used by the existing signing engine.
    /// Validation occurs before replacing any active signing assets.
    static func activateArchive(p12Data: Data, provisionData: Data, password: String) throws {
        _ = try details(p12Data: p12Data, provisionData: provisionData, password: password)
        guard let p12Target = storedP12, let provisionTarget = storedProvision else {
            throw StoreInstallError.missingSigningAssets
        }
        let oldP12 = try? Data(contentsOf: p12Target)
        let oldProvision = try? Data(contentsOf: provisionTarget)
        let oldPassword = loadPassword()
        do {
            try p12Data.write(to: p12Target, options: [.atomic, .completeFileProtectionUnlessOpen])
            try provisionData.write(to: provisionTarget, options: [.atomic, .completeFileProtectionUnlessOpen])
            try savePassword(password)
        } catch {
            if let oldP12 { try? oldP12.write(to: p12Target, options: .atomic) }
            if let oldProvision { try? oldProvision.write(to: provisionTarget, options: .atomic) }
            if let oldPassword { try? savePassword(oldPassword) }
            throw error
        }
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

    /// BatSign-style import: read both picker URLs while access is valid,
    /// validate the pair and password first, then persist our own copies.
    static func importCertificate(p12URL: URL, profileURL: URL, password: String) throws {
        let inspected = try inspectCertificate(p12URL: p12URL, profileURL: profileURL, password: password)
        try activateArchive(
            p12Data: inspected.p12Data, provisionData: inspected.provisionData, password: password
        )
    }

    static func importP12(from source: URL) throws {
        guard source.pathExtension.lowercased() == "p12" else {
            throw SigningAssetError.wrongP12Extension
        }
        guard let target = storedP12 else { throw StoreInstallError.missingSigningAssets }
        let data = try readSecurityScopedData(from: source)
        guard !data.isEmpty else { throw SigningAssetError.emptyFile(source.lastPathComponent) }
        try data.write(to: target, options: [.atomic])
    }

    static func importProvision(from source: URL) throws {
        guard source.pathExtension.lowercased() == "mobileprovision" else {
            throw SigningAssetError.wrongProvisionExtension
        }
        guard let target = storedProvision else { throw StoreInstallError.missingSigningAssets }
        let data = try readSecurityScopedData(from: source)
        guard !data.isEmpty else { throw SigningAssetError.emptyFile(source.lastPathComponent) }
        _ = try provisionDictionary(data: data)
        try data.write(to: target, options: [.atomic])
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
        let p12Data = try Data(contentsOf: credentials.p12)
        let provisionData = try Data(contentsOf: credentials.mobileProvision)
        let identityCertificate = try identityCertificateData(p12Data: p12Data, password: credentials.password)
        let provision = try provisionDictionary(data: provisionData)
        try validate(identityCertificate: identityCertificate, provision: provision)
    }

    private static func validate(identityCertificate: Data, provision: [String: Any]) throws {
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

    private static func identityCertificateData(
        p12Data: Data, password: String, expectedCertificates: [Data]? = nil
    ) throws -> Data {
        guard !p12Data.isEmpty else { throw SigningAssetError.invalidP12 }

        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12Data as CFData, options, &imported)

        var candidates: [Data] = []
        if status == errSecSuccess, let entries = imported as? [[String: Any]] {
            // Not every P12 returns its signing identity as its first item.
            for entry in entries {
                guard let identityValue = entry[kSecImportItemIdentity as String] else { continue }
                let identity = identityValue as! SecIdentity
                var certificate: SecCertificate?
                if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                   let certificate {
                    candidates.append(SecCertificateCopyData(certificate) as Data)
                }
            }
        }

        // The fast Security.framework path succeeded: avoid an unnecessary
        // second PKCS12 parse on every settings/certificate validation.
        if let expectedCertificates, !expectedCertificates.isEmpty,
           let matched = candidates.first(where: { expectedCertificates.contains($0) }) {
            return matched
        }
        if expectedCertificates == nil, let first = candidates.first {
            return first
        }

        // OpenSSL 3 (already used by the signing engine) can decode modern
        // AES/PBES2 PKCS12 files that Security.framework sometimes rejects.
        if let fallback = Zsign.certificateDER(p12Data: p12Data, password: password),
           !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        if let expectedCertificates, !expectedCertificates.isEmpty,
           let matched = candidates.first(where: { expectedCertificates.contains($0) }) {
            return matched
        }
        if let first = candidates.first { return first }

        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
            throw SigningAssetError.badP12Password
        }
        if status != errSecSuccess {
            throw SigningAssetError.unsupportedP12Format(Int(status))
        }
        throw SigningAssetError.invalidP12
    }

    private static func provisionDictionary(data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw SigningAssetError.invalidProvision }

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

    private static func readSecurityScopedData(from source: URL) throws -> Data {
        let granted = source.startAccessingSecurityScopedResource()
        defer {
            if granted { source.stopAccessingSecurityScopedResource() }
        }
        do {
            return try Data(contentsOf: source, options: [.mappedIfSafe])
        } catch {
            throw SigningAssetError.emptyFile(source.lastPathComponent)
        }
    }
}