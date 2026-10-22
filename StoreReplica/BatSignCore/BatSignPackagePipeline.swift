import Foundation
import Zip

enum BatSignPackageError: LocalizedError {
    case unreadablePackage
    case payloadNotFound
    case appNotFound
    case invalidMetadata
    case archiveFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePackage: return "تعذر قراءة حزمة IPA."
        case .payloadNotFound: return "لم يتم العثور على مجلد Payload داخل IPA."
        case .appNotFound: return "لم يتم العثور على تطبيق .app داخل Payload."
        case .invalidMetadata: return "تعذر قراءة Info.plist للتطبيق."
        case .archiveFailed: return "تعذر تجهيز IPA الموقّع للتثبيت."
        }
    }
}

enum BatSignPackageStage { case unpacking, signing, packaging }

struct BatSignPackageArtifact {
    let ipaURL: URL
    let name: String
    let bundleID: String
    let version: String
}

enum BatSignPackagePipeline {
    private static let fm = FileManager.default

    static func sign(ipaURL: URL, job: StoreInstallJob, credentials: SigningAssetProvider.Credentials, outputURL: URL, progress: ((BatSignPackageStage, Double) -> Void)? = nil) throws -> BatSignPackageArtifact {
        if let cached = BatSignSignedCache.materializeForInstall(job: job, credentials: credentials) {
            prewarmGBoxManifest(name: cached.name, bundleID: cached.bundleID, version: cached.version)
            progress?(.packaging, 1)
            return cached
        }

        let root = fm.temporaryDirectory.appendingPathComponent("BatSignCore-\(job.id)-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        do {
            progress?(.unpacking, 0)
            Zip.addCustomFileExtension("ipa")
            try Zip.unzipFile(ipaURL, destination: root, overwrite: true, password: nil, progress: { progress?(.unpacking, $0) })
            progress?(.unpacking, 1)
        } catch { throw BatSignPackageError.unreadablePackage }

        guard let payload = locatePayload(in: root) else { throw BatSignPackageError.payloadNotFound }
        guard let appURL = locateApp(in: payload) else { throw BatSignPackageError.appNotFound }

        let metadata = try readMetadata(appURL: appURL, fallback: job)
        let requestedBundle = job.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = job.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVersion = job.version.trimmingCharacters(in: .whitespacesAndNewlines)

        let bundleOverride = !requestedBundle.isEmpty && requestedBundle != metadata.bundleID ? requestedBundle : nil
        let nameOverride = !requestedName.isEmpty && requestedName != metadata.name ? requestedName : nil
        let versionOverride = !requestedVersion.isEmpty && requestedVersion != metadata.version ? requestedVersion : nil

        let finalName = nameOverride ?? metadata.name
        let finalBundle = bundleOverride ?? metadata.bundleID
        let finalVersion = versionOverride ?? metadata.version
        prewarmGBoxManifest(name: finalName, bundleID: finalBundle, version: finalVersion)

        progress?(.signing, 0)
        try BatSignSigner.sign(appURL: appURL, credentials: credentials, bundleID: bundleOverride, displayName: nameOverride, version: versionOverride)
        progress?(.signing, 1)

        let zipURL = outputURL.deletingPathExtension().appendingPathExtension("zip")
        try? fm.removeItem(at: zipURL)
        try? fm.removeItem(at: outputURL)
        do {
            progress?(.packaging, 0)
            try Zip.zipFiles(paths: [payload], zipFilePath: zipURL, password: nil, compression: .BestSpeed, progress: { progress?(.packaging, $0) })
            try fm.moveItem(at: zipURL, to: outputURL)
            progress?(.packaging, 1)
        } catch {
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: outputURL)
            throw BatSignPackageError.archiveFailed
        }

        let artifact = BatSignPackageArtifact(ipaURL: outputURL, name: finalName, bundleID: finalBundle, version: finalVersion)
        try? BatSignSignedCache.store(artifact: artifact, job: job, credentials: credentials)
        return artifact
    }

    static func locatePayload(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("Payload", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: direct.path, isDirectory: &isDirectory), isDirectory.boolValue { return direct }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "Payload" else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return url }
        }
        return nil
    }

    static func locateApp(in payload: URL) -> URL? {
        if let direct = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]), let app = direct.first(where: { $0.pathExtension.lowercased() == "app" }) { return app }
        guard let enumerator = fm.enumerator(at: payload, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" { return url }
        return nil
    }

    static func validateImportableIPA(at url: URL) -> Bool {
        let root = fm.temporaryDirectory.appendingPathComponent("BatSignValidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            Zip.addCustomFileExtension("ipa")
            try Zip.unzipFile(url, destination: root, overwrite: true, password: nil, progress: nil)
            guard let payload = locatePayload(in: root), locateApp(in: payload) != nil else { return false }
            return true
        } catch { return false }
    }

    private static func readMetadata(appURL: URL, fallback job: StoreInstallJob) throws -> (name: String, bundleID: String, version: String) {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw BatSignPackageError.invalidMetadata }
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = plist[key] as? String {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
            return nil
        }
        let name = string(["CFBundleDisplayName", "CFBundleName"]) ?? job.appName
        let bundle = string(["CFBundleIdentifier"]) ?? job.bundleID
        let version = string(["CFBundleShortVersionString", "CFBundleVersion"]) ?? job.version
        guard !bundle.isEmpty else { throw BatSignPackageError.invalidMetadata }
        return (name, bundle, version.isEmpty ? "1.0" : version)
    }

    private static func prewarmGBoxManifest(name: String, bundleID: String, version: String) {
        let descriptor = "\(name)/\(bundleID)/\(version)"
        let base64 = Data(descriptor.utf8).base64EncodedString()
        let encoded = base64.replacingOccurrences(of: "=", with: "%3D")
        guard let url = URL(string: "https://i.gbox.run/\(encoded).plist") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 15
        request.setValue("text/xml,application/xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
