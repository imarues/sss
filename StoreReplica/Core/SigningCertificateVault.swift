import SwiftUI
import Security
import UIKit

struct StoredSigningCertificate: Codable, Identifiable {
    let id: String
    let name: String
    let profileUUID: String
    let expiresAt: Date
    let udids: [String]
    let importedAt: Date

    var isValid: Bool { expiresAt > Date() }
    var daysRemaining: Int { max(0, Int(ceil(expiresAt.timeIntervalSinceNow / 86_400))) }
    var progress: Double { max(0, min(1, expiresAt.timeIntervalSinceNow / (365 * 86_400))) }

    var udidLabel: String {
        let current = UserDefaults.standard.string(forKey: "store.deviceUDID") ?? ""
        if !current.isEmpty, udids.contains(current) { return current }
        if udids.count == 1 { return udids[0] }
        if udids.count > 1 { return udids.joined(separator: ", ") }
        return "—"
    }
}

@MainActor
final class SigningCertificateVault: ObservableObject {
    static let shared = SigningCertificateVault()

    @Published private(set) var certificates: [StoredSigningCertificate] = []
    @Published private(set) var activeID: String?

    private let keychainService = "com.ikiraplus.turathreplica.certificate-vault"
    private let activeKey = "store.activeSigningCertificateID"

    private var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SigningAssets/CertificateVault", isDirectory: true)
    }
    private var indexURL: URL { root.appendingPathComponent("certificates.json") }
    private func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private init() { loadIndex() }

    var active: StoredSigningCertificate? {
        certificates.first(where: { $0.id == activeID })
    }

    /// Picks up a certificate imported earlier through the existing signing flow.
    func refresh() {
        loadIndex()
        guard SigningAssetProvider.hasP12File && SigningAssetProvider.hasProvisionFile,
              let credentials = try? SigningAssetProvider.credentials(),
              let details = try? SigningAssetProvider.details(credentials: credentials) else { return }
        if let existing = certificates.first(where: { $0.profileUUID == details.profileUUID }) {
            if activeID != existing.id {
                activeID = existing.id
                persistIndex()
            }
            return
        }
        do {
            try archive(credentials: credentials, details: details)
        } catch {
            // The active signer stays usable even if the secondary vault is unavailable.
        }
    }

    func add(p12URL: URL, profileURL: URL, password: String) async throws {
        // The existing signer validates certificate/profile matching and its password.
        // This also keeps the most recently imported certificate active for signing.
        try await Task.detached(priority: .userInitiated) {
            try SigningAssetProvider.importCertificate(p12URL: p12URL, profileURL: profileURL, password: password)
        }.value
        let credentials = try SigningAssetProvider.credentials()
        let details = try SigningAssetProvider.details(credentials: credentials)
        try archive(credentials: credentials, details: details)
    }

    func activate(_ certificate: StoredSigningCertificate) async throws {
        guard let password = loadPassword(id: certificate.id) else {
            throw NSError(domain: "CertificateVault", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "تعذر العثور على رمز الشهادة المحفوظ"])
        }
        let folder = folder(for: certificate.id)
        let p12 = try Data(contentsOf: folder.appendingPathComponent("certificate.p12"))
        let profile = try Data(contentsOf: folder.appendingPathComponent("certificate.mobileprovision"))
        try await Task.detached(priority: .userInitiated) {
            try SigningAssetProvider.activateArchive(p12Data: p12, provisionData: profile, password: password)
        }.value
        activeID = certificate.id
        persistIndex()
    }

    func delete(_ certificate: StoredSigningCertificate) {
        if activeID == certificate.id {
            SigningAssetProvider.clearActiveCertificate()
        }
        try? FileManager.default.removeItem(at: folder(for: certificate.id))
        deletePassword(id: certificate.id)
        certificates.removeAll(where: { $0.id == certificate.id })
        if activeID == certificate.id { activeID = nil }
        persistIndex()
    }

    private func archive(credentials: SigningAssetProvider.Credentials,
                         details: SigningAssetProvider.CertificateDetails) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let path = folder(for: id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        do {
            try Data(contentsOf: credentials.p12).write(
                to: path.appendingPathComponent("certificate.p12"),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            try Data(contentsOf: credentials.mobileProvision).write(
                to: path.appendingPathComponent("certificate.mobileprovision"),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            try savePassword(credentials.password, id: id)
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw error
        }
        let record = StoredSigningCertificate(
            id: id, name: details.name, profileUUID: details.profileUUID,
            expiresAt: details.expiration, udids: details.provisionedUDIDs, importedAt: Date()
        )
        certificates.insert(record, at: 0)
        activeID = id
        persistIndex()
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([StoredSigningCertificate].self, from: data) {
            certificates = saved.sorted { $0.importedAt > $1.importedAt }
        }
        activeID = UserDefaults.standard.string(forKey: activeKey)
    }

    private func persistIndex() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(certificates).write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            UserDefaults.standard.set(activeID, forKey: activeKey)
        } catch {
            // Preserve the in-memory state; the UI can retry the operation.
        }
    }

    private func keychainQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id
        ]
    }

    private func savePassword(_ password: String, id: String) throws {
        let query = keychainQuery(id: id)
        SecItemDelete(query as CFDictionary)
        var newItem = query
        newItem[kSecValueData as String] = Data(password.utf8)
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(newItem as CFDictionary, nil)
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }

    private func loadPassword(id: String) -> String? {
        var query = keychainQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deletePassword(id: String) {
        SecItemDelete(keychainQuery(id: id) as CFDictionary)
    }

    static var actualDeviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !["iPhone", "iPad"].contains(name) { return name }
        var system = utsname()
        uname(&system)
        let identifier = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: system.machine)) {
                String(cString: $0)
            }
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
