import Foundation
import CryptoKit

private struct BatSignSignedCacheRecord: Codable {
    let name: String
    let bundleID: String
    let version: String
    let sourceVersion: String
    let certificateFingerprint: String
}

enum BatSignSignedCache {
    private static let fm = FileManager.default

    private static var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BatSignSignedCache", isDirectory: true)
    }

    /// Preserve a successfully signed IPA without copying hundreds of megabytes.
    /// Application Support and Caches are on the app data volume, so a hard link
    /// normally makes this instant. Copy is only a fallback for unusual layouts.
    static func store(
        artifact: BatSignPackageArtifact,
        job: StoreInstallJob,
        credentials: SigningAssetProvider.Credentials
    ) throws {
        let fingerprint = try certificateFingerprint(credentials)
        let directory = cacheDirectory(job: job, fingerprint: fingerprint)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ipa = directory.appendingPathComponent("signed.ipa")
        let recordURL = directory.appendingPathComponent("metadata.json")
        let incoming = directory.appendingPathComponent("signed.ipa.incoming-\(UUID().uuidString)")
        try? fm.removeItem(at: incoming)
        defer { try? fm.removeItem(at: incoming) }

        do {
            try fm.linkItem(at: artifact.ipaURL, to: incoming)
        } catch {
            try fm.copyItem(at: artifact.ipaURL, to: incoming)
        }
        guard StoreDownloadStorage.isValidIPA(at: incoming) else {
            throw StoreDownloadStorageError.invalidIPA
        }

        if fm.fileExists(atPath: ipa.path) {
            _ = try fm.replaceItemAt(ipa, withItemAt: incoming)
        } else {
            try fm.moveItem(at: incoming, to: ipa)
        }

        let record = BatSignSignedCacheRecord(
            name: artifact.name,
            bundleID: artifact.bundleID,
            version: artifact.version,
            sourceVersion: job.version,
            certificateFingerprint: fingerprint
        )
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: ipa.path
        )
    }

    /// Return a temporary hard-link to the persistent signed package. The install
    /// engine may delete this temporary URL freely; the cached inode stays alive.
    static func materializeForInstall(
        job: StoreInstallJob,
        credentials: SigningAssetProvider.Credentials
    ) -> BatSignPackageArtifact? {
        guard let cached = cached(job: job, credentials: credentials) else { return nil }
        let tempRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatSignSigned", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let temporary = tempRoot.appendingPathComponent("\(job.id)-cached-signed.ipa")
        try? fm.removeItem(at: temporary)
        do {
            try fm.linkItem(at: cached.ipaURL, to: temporary)
        } catch {
            do { try fm.copyItem(at: cached.ipaURL, to: temporary) }
            catch { return nil }
        }
        return BatSignPackageArtifact(
            ipaURL: temporary,
            name: cached.name,
            bundleID: cached.bundleID,
            version: cached.version
        )
    }

    static func invalidate(job: StoreInstallJob) {
        let appRoot = root.appendingPathComponent(safe(job.appID), isDirectory: true)
        try? fm.removeItem(at: appRoot)
    }

    private static func cached(
        job: StoreInstallJob,
        credentials: SigningAssetProvider.Credentials
    ) -> BatSignPackageArtifact? {
        guard let fingerprint = try? certificateFingerprint(credentials) else { return nil }
        let directory = cacheDirectory(job: job, fingerprint: fingerprint)
        let ipa = directory.appendingPathComponent("signed.ipa")
        let recordURL = directory.appendingPathComponent("metadata.json")
        guard StoreDownloadStorage.isValidIPA(at: ipa),
              let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(BatSignSignedCacheRecord.self, from: data),
              record.sourceVersion == job.version,
              record.certificateFingerprint == fingerprint else { return nil }
        return BatSignPackageArtifact(
            ipaURL: ipa,
            name: record.name,
            bundleID: record.bundleID,
            version: record.version
        )
    }

    private static func cacheDirectory(job: StoreInstallJob, fingerprint: String) -> URL {
        root
            .appendingPathComponent(safe(job.appID), isDirectory: true)
            .appendingPathComponent(safe(job.version), isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
    }

    private static func certificateFingerprint(_ credentials: SigningAssetProvider.Credentials) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: credentials.p12))
        hasher.update(data: try Data(contentsOf: credentials.mobileProvision))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safe(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = value.components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "app" : String(cleaned.prefix(100))
    }
}
