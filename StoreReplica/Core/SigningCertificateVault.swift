import SwiftUI
import Security
import UIKit

struct StoredSigningCertificate: Codable, Identifiable {
    let id: String
    let name: String
    let profileUUID: String
    let certificateSHA256: String?
    let expiresAt: Date
    let udids: [String]
    let importedAt: Date

    var displayName: String {
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "iPhone Distribution:", "Apple Distribution:",
            "iOS Distribution:", "iPhone Developer:",
            "Apple Development:", "iOS Development:"
        ]
        for prefix in prefixes where original.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
            let remainder = String(original.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { return remainder }
        }
        return original
    }

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
    func refresh() async {
        loadIndex()
        // PKCS12 decoding and crypto verification are too expensive for the
        // UI main actor; opening account/settings must remain responsive.
        let scanned = await Task.detached(priority: .utility) {
            () -> (SigningAssetProvider.Credentials, SigningAssetProvider.CertificateDetails)? in
            guard SigningAssetProvider.hasP12File && SigningAssetProvider.hasProvisionFile,
                  let credentials = try? SigningAssetProvider.credentials(),
                  let details = try? SigningAssetProvider.details(credentials: credentials)
            else { return nil }
            return (credentials, details)
        }.value
        guard let (credentials, details) = scanned else { return }
        if let existing = certificates.first(where: {
            $0.profileUUID == details.profileUUID &&
            ($0.certificateSHA256 == details.certificateSHA256 ||
             ($0.certificateSHA256 == nil && $0.name == details.name))
        }) {
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
        // Never overwrite the active P12 while simply inspecting a new one.
        let inspected = try await Task.detached(priority: .userInitiated) {
            try SigningAssetProvider.inspectCertificate(
                p12URL: p12URL, profileURL: profileURL, password: password
            )
        }.value

        if let existing = certificates.first(where: {
            $0.profileUUID == inspected.details.profileUUID &&
            $0.certificateSHA256 == inspected.details.certificateSHA256
        }) {
            try await activate(existing)
            return
        }

        // Archive and Keychain must succeed before the signing engine switches
        // identity. If activation fails, discard the new archive only.
        let record = try storeArchive(
            p12Data: inspected.p12Data, provisionData: inspected.provisionData,
            password: password, details: inspected.details
        )
        do {
            try await Task.detached(priority: .userInitiated) {
                try SigningAssetProvider.activateArchive(
                    p12Data: inspected.p12Data,
                    provisionData: inspected.provisionData,
                    password: password
                )
            }.value
        } catch {
            try? FileManager.default.removeItem(at: folder(for: record.id))
            deletePassword(id: record.id)
            throw error
        }
        certificates.insert(record, at: 0)
        activeID = record.id
        persistIndex()
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
        let record = try storeArchive(
            p12Data: Data(contentsOf: credentials.p12),
            provisionData: Data(contentsOf: credentials.mobileProvision),
            password: credentials.password, details: details
        )
        certificates.insert(record, at: 0)
        activeID = record.id
        persistIndex()
    }

    private func storeArchive(
        p12Data: Data, provisionData: Data, password: String,
        details: SigningAssetProvider.CertificateDetails
    ) throws -> StoredSigningCertificate {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let path = folder(for: id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        do {
            try p12Data.write(
                to: path.appendingPathComponent("certificate.p12"),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            try provisionData.write(
                to: path.appendingPathComponent("certificate.mobileprovision"),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            try savePassword(password, id: id)
        } catch {
            try? FileManager.default.removeItem(at: path)
            deletePassword(id: id)
            throw error
        }
        return StoredSigningCertificate(
            id: id, name: details.name,
            profileUUID: details.profileUUID,
            certificateSHA256: details.certificateSHA256,
            expiresAt: details.expiration,
            udids: details.provisionedUDIDs,
            importedAt: Date()
        )
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

    /// Model shown on the signing account card; independent of any certificate or UDID.
    /// Keep the exact hardware lookup separate from certificate-provisioning logic.
    static var actualDeviceName: String {
        var system = utsname()
        uname(&system)
        let machineCapacity = MemoryLayout.size(ofValue: system.machine)
        let identifier = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: machineCapacity) {
                String(cString: $0)
            }
        }
        #if targetEnvironment(simulator)
        let hardwareIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? identifier
        #else
        let hardwareIdentifier = identifier
        #endif
        // Never claim that an unknown identifier is a specific iPhone model.
        return TurathDeviceModelName.name(for: hardwareIdentifier) ?? UIDevice.current.model
    }
}


/// Apple hardware identifiers -> commercial device names (iPhone 5 onward,
/// all iPad families through iPad Pro M5, and iPhone 18 Pro Max / Duo).
/// Entries are hardware-model mappings, NOT UDID or signing-certificate data.
/// New identifiers fall back to the system's generic "iPhone"/"iPad" label.
private enum TurathDeviceModelName {
    static func name(for identifier: String) -> String? {
        switch identifier {
        case "iPad1,1", "iPad1,2": return "iPad (1st generation)"
        case "iPhone5,1", "iPhone5,2": return "iPhone 5"
        case "iPhone5,3", "iPhone5,4": return "iPhone 5c"
        case "iPhone6,1", "iPhone6,2": return "iPhone 5s"
        case "iPhone7,2": return "iPhone 6"
        case "iPhone7,1": return "iPhone 6 Plus"
        case "iPhone8,1": return "iPhone 6s"
        case "iPhone8,2": return "iPhone 6s Plus"
        case "iPhone9,1", "iPhone9,3": return "iPhone 7"
        case "iPhone9,2", "iPhone9,4": return "iPhone 7 Plus"
        case "iPhone8,4": return "iPhone SE (1st generation)"
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"
        case "iPhone12,8": return "iPhone SE (2nd generation)"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,1": return "iPhone 12 mini"
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,6": return "iPhone SE (3rd generation)"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,5": return "iPhone 16e"
        case "iPhone18,3": return "iPhone 17"
        case "iPhone18,1": return "iPhone 17 Pro"
        case "iPhone18,2": return "iPhone 17 Pro Max"
        case "iPhone18,4": return "iPhone Air"
        case "iPhone18,5": return "iPhone 17e"
        case "iPhone19,2": return "iPhone 18 Pro"
        case "iPhone19,3", "iPhone19,7": return "iPhone 18 Pro Max"
        case "iPad2,1", "iPad2,2", "iPad2,3", "iPad2,4": return "iPad 2"
        case "iPad3,1", "iPad3,2", "iPad3,3": return "iPad (3rd generation)"
        case "iPad3,4", "iPad3,5", "iPad3,6": return "iPad (4th generation)"
        case "iPad4,1", "iPad4,2", "iPad4,3": return "iPad Air"
        case "iPad5,3", "iPad5,4": return "iPad Air 2"
        case "iPad6,11", "iPad6,12": return "iPad (5th generation)"
        case "iPad7,5", "iPad7,6": return "iPad (6th generation)"
        case "iPad11,3", "iPad11,4": return "iPad Air (3rd generation)"
        case "iPad7,11", "iPad7,12": return "iPad (7th generation)"
        case "iPad11,6", "iPad11,7": return "iPad (8th generation)"
        case "iPad12,1", "iPad12,2": return "iPad (9th generation)"
        case "iPad13,18", "iPad13,19": return "iPad (10th generation)"
        case "iPad15,7", "iPad15,8": return "iPad (A16)"
        case "iPad13,1", "iPad13,2": return "iPad Air (4th generation)"
        case "iPad13,16", "iPad13,17": return "iPad Air (5th generation)"
        case "iPad14,8", "iPad14,9": return "iPad Air 11-inch (M2)"
        case "iPad14,10", "iPad14,11": return "iPad Air 13-inch (M2)"
        case "iPad15,3", "iPad15,4": return "iPad Air 11-inch (M3)"
        case "iPad15,5", "iPad15,6": return "iPad Air 13-inch (M3)"
        case "iPad16,8", "iPad16,9": return "iPad Air 11-inch (M4)"
        case "iPad16,10", "iPad16,11": return "iPad Air 13-inch (M4)"
        case "iPad2,5", "iPad2,6", "iPad2,7": return "iPad mini (1st generation)"
        case "iPad4,4", "iPad4,5", "iPad4,6": return "iPad mini 2"
        case "iPad4,7", "iPad4,8", "iPad4,9": return "iPad mini 3"
        case "iPad5,1", "iPad5,2": return "iPad mini 4"
        case "iPad11,1", "iPad11,2": return "iPad mini (5th generation)"
        case "iPad14,1", "iPad14,2": return "iPad mini (6th generation)"
        case "iPad16,1", "iPad16,2": return "iPad mini (A17 Pro)"
        case "iPad6,3", "iPad6,4": return "iPad Pro 9.7-inch"
        case "iPad6,7", "iPad6,8": return "iPad Pro 12.9-inch (1st generation)"
        case "iPad7,1", "iPad7,2": return "iPad Pro 12.9-inch (2nd generation)"
        case "iPad7,3", "iPad7,4": return "iPad Pro 10.5-inch"
        case "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4": return "iPad Pro 11-inch (1st generation)"
        case "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8": return "iPad Pro 12.9-inch (3rd generation)"
        case "iPad8,9", "iPad8,10": return "iPad Pro 11-inch (2nd generation)"
        case "iPad8,11", "iPad8,12": return "iPad Pro 12.9-inch (4th generation)"
        case "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7": return "iPad Pro 11-inch (3rd generation)"
        case "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11": return "iPad Pro 12.9-inch (5th generation)"
        case "iPad14,3", "iPad14,4": return "iPad Pro 11-inch (4th generation)"
        case "iPad14,5", "iPad14,6": return "iPad Pro 12.9-inch (6th generation)"
        case "iPad16,3", "iPad16,4": return "iPad Pro 11-inch (M4)"
        case "iPad16,5", "iPad16,6": return "iPad Pro 13-inch (M4)"
        case "iPad17,1", "iPad17,2": return "iPad Pro 11-inch (M5)"
        case "iPad17,3", "iPad17,4": return "iPad Pro 13-inch (M5)"
        case "iPhone19,4": return "iPhone Duo"
        default: return nil
        }
    }
}
